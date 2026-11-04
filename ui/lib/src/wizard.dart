import 'package:dragon_dice/dragon_dice.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'entropy_chart.dart';

/// The cue names the wizard reports through [DragonDiceWizard.onCue], for a
/// host that voices them. A press is `press.dice.<control>`.
abstract final class DiceCue {
  static const String addDie = 'press.dice.add';
  static const String selectDie = 'press.dice.select';
  static const String removeDie = 'press.dice.remove';
  static const String rolls = 'press.dice.rolls';
  static const String undo = 'press.dice.undo';
  static const String reveal = 'press.dice.reveal';
  static const String advanced = 'press.dice.advanced';
  static const String setting = 'press.dice.setting';
  static const String done = 'press.dice.done';
  static const String cancel = 'press.dice.cancel';

  /// A typed line that is not rolls of the current die.
  static const String badRoll = 'denyInput';

  /// The rolls just reached the target.
  static const String ready = 'confirm';

  /// The warning before finishing short of the target.
  static const String short = 'alert.warning';

  static const List<String> all = <String>[
    addDie,
    selectDie,
    removeDie,
    rolls,
    undo,
    reveal,
    advanced,
    setting,
    done,
    cancel,
    badRoll,
    ready,
    short,
  ];
}

/// The default bound on the chance of falling short (advanced mode).
const double kDefaultBound = 0.01;

/// The bounds offered (advanced mode).
const List<double> kBounds = <double>[0.001, 0.01, 0.05];

/// The Monte Carlo draws offered (advanced mode).
const List<int> kSampleChoices = <int>[5000, kDefaultSamples, 50000];

/// Width of the dice column, in logical pixels.
const double _kDiceColumnWidth = 300;

/// The total chart's share of the height, against the per-roll chart's 1.
const int _kTotalChartFlex = 2;

/// The Dragon Dice wizard: add dice, type their rolls, watch the entropy
/// they carry reach [targetBits], and finish.
///
/// Vanilla, rolls are ready once they carry the target if the dice are fair.
/// In advanced mode, once the Bayesian estimate's chance of falling short is
/// at most the bound. Finishing short of the target is allowed after an
/// emphatic warning; finishing without a single roll is not (its digest is
/// public).
///
/// The rolls are handed to [onDone] and forgotten: the receiver owns them
/// and wipes them ([DiceRolls.wipe]). Rolls typed are hidden by default.
class DragonDiceWizard extends StatefulWidget {
  const DragonDiceWizard({
    super.key,
    required this.targetBits,
    required this.onDone,
    this.onCancel,
    this.onCue,
    this.title = 'Dragon Dice',
    this.purpose,
    this.startAdvanced = false,
  });

  final double targetBits;
  final ValueChanged<DiceRolls> onDone;
  final VoidCallback? onCancel;

  /// Reports [DiceCue] names, for a host that plays sounds.
  final ValueChanged<String>? onCue;
  final String title;

  /// What the rolls are for, shown under the title.
  final String? purpose;
  final bool startAdvanced;

  @override
  State<DragonDiceWizard> createState() => _DragonDiceWizardState();
}

class _DragonDiceWizardState extends State<DragonDiceWizard> {
  DiceRolls _rolls = DiceRolls();
  int? _current;
  late bool _advanced = widget.startAdvanced;
  bool _hidden = true;
  String? _error;

  Prior _prior = Prior.flat;
  bool _customPrior = false;
  final TextEditingController _alpha = TextEditingController();
  EntropyMeasure _measure = EntropyMeasure.min;
  double _bound = kDefaultBound;
  int _samples = kDefaultSamples;

  final TextEditingController _entry = TextEditingController();
  final FocusNode _entryFocus = FocusNode(debugLabel: 'dice-rolls');
  final TextEditingController _customFaces = TextEditingController();

  _Estimates? _estimates;
  int _generation = 0;
  bool _wasReady = false;

  double get _target => widget.targetBits;

  EstimatorSettings get _settings =>
      EstimatorSettings(prior: _prior, measure: _measure, samples: _samples);

  /// Whether the estimate in hand is for the rolls and settings as they are.
  bool get _fresh => _estimates?.generation == _generation;

  bool get _ready {
    if (_rolls.rollCount == 0) return false;
    if (!_advanced) return _rolls.fairBits >= _target;
    final _Estimates? e = _estimates;
    return _fresh && e != null && e.total.probabilityBelow(_target) <= _bound;
  }

  void _cue(String name) => widget.onCue?.call(name);

  @override
  void dispose() {
    _rolls.wipe();
    _entry.dispose();
    _entryFocus.dispose();
    _alpha.dispose();
    _customFaces.dispose();
    super.dispose();
  }

  // --- editing ---------------------------------------------------------------

  void _changed() {
    _generation++;
    _error = null;
    final bool ready = _ready;
    if (ready && !_wasReady) _cue(DiceCue.ready);
    _wasReady = ready;
    setState(() {});
    if (_advanced) _estimate();
  }

  void _addDie(int faces) {
    _cue(DiceCue.addDie);
    _rolls.dice.add(DieRolls(Die(faces)));
    _current = _rolls.dice.length - 1;
    _changed();
    _entryFocus.requestFocus();
  }

  void _addCustomDie() {
    final int? faces = int.tryParse(_customFaces.text.trim());
    if (faces == null || faces < kMinFaces || faces > kMaxFaces) {
      _cue(DiceCue.badRoll);
      setState(() => _error = 'A die has $kMinFaces–$kMaxFaces faces.');
      return;
    }
    _customFaces.clear();
    _addDie(faces);
  }

  void _selectDie(int i) {
    _cue(DiceCue.selectDie);
    setState(() => _current = i);
    if (_advanced) _estimate();
    _entryFocus.requestFocus();
  }

  void _removeDie(int i) {
    _cue(DiceCue.removeDie);
    _rolls.dice.removeAt(i).wipe();
    final int? c = _current;
    _current = _rolls.dice.isEmpty
        ? null
        : c == null || c >= _rolls.dice.length
            ? _rolls.dice.length - 1
            : c;
    _changed();
  }

  /// Enter in the rolls field: add the line's rolls, or finish on an empty
  /// line.
  void _submit(String text) {
    if (text.trim().isEmpty) {
      _done();
      return;
    }
    final int? c = _current;
    if (c == null) return;
    final DieRolls die = _rolls.dice[c];
    final List<int> parsed = <int>[];
    try {
      for (final String t in text.trim().split(RegExp(r'[\s,]+'))) {
        parsed.add(die.die.parseRoll(t));
      }
    } on FormatException catch (e) {
      _cue(DiceCue.badRoll);
      setState(() => _error = '${e.message} — the line was not added.');
      _entryFocus.requestFocus();
      return;
    }
    _cue(DiceCue.rolls);
    parsed.forEach(die.add);
    parsed.fillRange(0, parsed.length, 0);
    _entry.clear();
    _changed();
    _entryFocus.requestFocus();
  }

  void _undo() {
    final int? c = _current;
    if (c == null || _rolls.dice[c].rolls.isEmpty) return;
    _cue(DiceCue.undo);
    _rolls.dice[c].rolls
      ..[_rolls.dice[c].rolls.length - 1] = 0
      ..removeLast();
    _changed();
  }

  Future<void> _done() async {
    _cue(DiceCue.done);
    if (_rolls.rollCount == 0) {
      _cue(DiceCue.badRoll);
      setState(() => _error = 'No rolls yet: their digest would be public.');
      return;
    }
    if (!_ready) {
      _cue(DiceCue.short);
      final bool go = await showDialog<bool>(
            context: context,
            builder: (BuildContext ctx) => _ShortDialog(message: _shortfall()),
          ) ??
          false;
      if (!go || !mounted) return;
    }
    final DiceRolls out = _rolls;
    setState(() {
      _rolls = DiceRolls();
      _current = null;
      _estimates = null;
    });
    widget.onDone(out);
  }

  String _shortfall() {
    final _Estimates? e = _estimates;
    if (_advanced && e != null && _fresh) {
      return 'There is a ${_pct(e.total.probabilityBelow(_target))} chance '
          'these rolls carry less than ${_target.toStringAsFixed(0)} bits '
          '(your bound: ${_pct(_bound)}).';
    }
    return 'Even from fair dice these rolls carry only '
        '${_rolls.fairBits.toStringAsFixed(1)} of '
        '${_target.toStringAsFixed(0)} bits.';
  }

  // --- the estimate ------------------------------------------------------------

  /// Estimate in a background isolate (about a tenth of a second); the latest
  /// request wins.
  Future<void> _estimate() async {
    final int generation = _generation;
    final int? c = _current;
    final _Job job = _Job(
      rolls: <({int faces, List<int> rolls})>[
        for (final DieRolls d in _rolls.dice)
          (faces: d.die.faces, rolls: List<int>.of(d.rolls)),
      ],
      current: c,
      settings: _settings,
      generation: generation,
    );
    final _Estimates e = await compute(_run, job);
    if (!mounted || e.generation != _generation) return;
    final bool ready = _rolls.rollCount > 0 &&
        e.total.probabilityBelow(_target) <= _bound;
    if (ready && !_wasReady) _cue(DiceCue.ready);
    _wasReady = ready;
    setState(() => _estimates = e);
  }

  void _setAdvanced(bool on) {
    _cue(DiceCue.advanced);
    setState(() => _advanced = on);
    _changed();
  }

  void _setting(VoidCallback change) {
    _cue(DiceCue.setting);
    change();
    _changed();
  }

  // --- layout ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(widget.title, style: theme.textTheme.titleLarge),
              ),
              const Text('Advanced'),
              Switch(value: _advanced, onChanged: _setAdvanced),
            ],
          ),
          Text(
            '${widget.purpose == null ? '' : '${widget.purpose} · '}'
            'Target ${_target.toStringAsFixed(0)} bits. Add each physical die '
            'you roll, type its rolls as they come, and press Enter on an '
            'empty line when done.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: _kDiceColumnWidth, child: _diceColumn(theme)),
                const VerticalDivider(width: 24),
                Expanded(child: _estimateColumn(theme)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(child: _status(theme)),
              TextButton(
                onPressed: widget.onCancel == null
                    ? null
                    : () {
                        _cue(DiceCue.cancel);
                        widget.onCancel!();
                      },
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _rolls.rollCount == 0 ? null : _done,
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diceColumn(ThemeData theme) {
    final int? c = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final int f in kStandardFaces)
              ActionChip(label: Text('D$f'), onPressed: () => _addDie(f)),
          ],
        ),
        if (_advanced) ...<Widget>[
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _customFaces,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixText: 'D',
                    labelText: 'Custom die',
                  ),
                  onSubmitted: (_) => _addCustomDie(),
                ),
              ),
              IconButton(
                tooltip: 'Add the custom die',
                icon: const Icon(Icons.add),
                onPressed: _addCustomDie,
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: <Widget>[
              for (int i = 0; i < _rolls.dice.length; i++)
                ListTile(
                  dense: true,
                  selected: i == c,
                  title: Text('${_rolls.dice[i].die.name} '
                      '· ${_rolls.dice[i].rolls.length} rolls'),
                  subtitle: Text('${_rolls.dice[i].fairBits.toStringAsFixed(1)} '
                      'bits if fair'),
                  onTap: () => _selectDie(i),
                  trailing: IconButton(
                    tooltip: 'Remove this die and its rolls',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _removeDie(i),
                  ),
                ),
            ],
          ),
        ),
        TextField(
          controller: _entry,
          focusNode: _entryFocus,
          enabled: c != null,
          obscureText: _hidden,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9 ,]')),
          ],
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: c == null
                ? 'Add a die first'
                : 'Rolls of the ${_rolls.dice[c].die.name}',
            hintText: '3 1 6 …',
            errorText: _error,
            errorMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: _hidden ? 'Show' : 'Hide',
              icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
              onPressed: () {
                _cue(DiceCue.reveal);
                setState(() => _hidden = !_hidden);
              },
            ),
          ),
          onSubmitted: _submit,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: c == null || _rolls.dice[c].rolls.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('Undo last roll'),
          ),
        ),
      ],
    );
  }

  Widget _estimateColumn(ThemeData theme) {
    if (!_advanced) {
      final double share = (_rolls.fairBits / _target).clamp(0.0, 1.0);
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '${_rolls.fairBits.toStringAsFixed(1)} of '
            '${_target.toStringAsFixed(0)} bits, if the dice are fair',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: share, minHeight: 8),
          const SizedBox(height: 12),
          Text(
            'Advanced mode estimates instead how likely it is that biased dice '
            'carry less than the target, and lets you choose the prior, the '
            'entropy measure and the bound.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }
    final _Estimates? e = _estimates;
    final int? c = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _settingsRows(theme),
        const SizedBox(height: 8),
        Expanded(
          flex: _kTotalChartFlex,
          child: e == null || _rolls.rollCount == 0
              ? const Center(child: Text('Roll to see the estimate.'))
              : EntropyChart(
                  distribution: e.total,
                  target: _target,
                  height: double.infinity,
                ),
        ),
        if (e != null && _rolls.rollCount > 0)
          Text(
            'Median ${e.total.median.toStringAsFixed(1)} bits · '
            '${_pct(e.total.probabilityBelow(_target))} chance below target '
            '(bound ${_pct(_bound)})${_fresh ? '' : ' · updating…'}',
            style: theme.textTheme.bodyMedium,
          ),
        if (e != null && c != null && e.perRollPosterior != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'One ${_rolls.dice[c].die.name} roll: before (outline) and after '
            '(filled) its rolls; the line is a fair die.',
            style: theme.textTheme.bodySmall,
          ),
          Expanded(
            child: EntropyChart(
              distribution: e.perRollPosterior!,
              reference: e.perRollPrior,
              marker: _rolls.dice[c].die.fairBits,
              height: double.infinity,
            ),
          ),
        ],
      ],
    );
  }

  Widget _settingsRows(ThemeData theme) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        DropdownButton<Prior?>(
          value: _customPrior ? null : _prior,
          hint: Text('Custom α=${_num(_prior.alpha)}'),
          items: <DropdownMenuItem<Prior?>>[
            for (final Prior p in Prior.presets)
              DropdownMenuItem<Prior?>(
                value: p,
                child: Text('${p.name} α=${_num(p.alpha)}'),
              ),
            const DropdownMenuItem<Prior?>(child: Text('Custom α…')),
          ],
          onChanged: (Prior? p) => _setting(() {
            _customPrior = p == null;
            if (p != null) _prior = p;
          }),
        ),
        if (_customPrior)
          SizedBox(
            width: 90,
            child: TextField(
              controller: _alpha,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, labelText: 'α > 0'),
              onSubmitted: (String v) {
                final double? a = double.tryParse(v.trim());
                if (a == null || a <= 0) {
                  _cue(DiceCue.badRoll);
                  return;
                }
                _setting(() => _prior = Prior(a, 'Custom'));
              },
            ),
          ),
        SegmentedButton<EntropyMeasure>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const <ButtonSegment<EntropyMeasure>>[
            ButtonSegment<EntropyMeasure>(
                value: EntropyMeasure.min, label: Text('Min')),
            ButtonSegment<EntropyMeasure>(
                value: EntropyMeasure.shannon, label: Text('Shannon')),
          ],
          selected: <EntropyMeasure>{_measure},
          onSelectionChanged: (Set<EntropyMeasure> s) =>
              _setting(() => _measure = s.first),
        ),
        DropdownButton<double>(
          value: _bound,
          items: <DropdownMenuItem<double>>[
            for (final double b in kBounds)
              DropdownMenuItem<double>(value: b, child: Text('≤ ${_pct(b)}')),
          ],
          onChanged: (double? b) => _setting(() => _bound = b ?? _bound),
        ),
        DropdownButton<int>(
          value: _samples,
          items: <DropdownMenuItem<int>>[
            for (final int n in kSampleChoices)
              DropdownMenuItem<int>(
                value: n,
                child: Text('${n ~/ _kThousand}k draws'),
              ),
          ],
          onChanged: (int? n) => _setting(() => _samples = n ?? _samples),
        ),
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (BuildContext ctx) => const _AdvancedHelp(),
          ),
          child: const Text('What do these mean?'),
        ),
      ],
    );
  }

  Widget _status(ThemeData theme) {
    final bool ready = _ready;
    final String text = _rolls.rollCount == 0
        ? 'No rolls yet.'
        : ready
            ? 'Ready — press Enter on an empty line, or Done.'
            : _advanced && !_fresh
                ? 'Estimating…'
                : 'Not enough yet. ${_shortfall()}';
    return Row(
      children: <Widget>[
        Icon(
          ready ? Icons.check_circle : Icons.casino_outlined,
          color: ready ? theme.colorScheme.primary : theme.colorScheme.outline,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// Thousands, for draw counts.
const int _kThousand = 1000;

/// [v] without a trailing `.0`.
String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

String _pct(double p) => '${(p * 100).toStringAsFixed(p < 0.1 ? 2 : 1)} %';

/// What the advanced fields mean (doc/ADVANCED.md, in short).
class _AdvancedHelp extends StatelessWidget {
  const _AdvancedHelp();

  @override
  Widget build(BuildContext context) {
    const List<(String, String)> items = <(String, String)>[
      (
        'The curve',
        'How much entropy your rolls carry, allowing that the dice may be '
            'biased. The red part falls short of the target; rolls are ready '
            'when its share is at most the bound.'
      ),
      (
        'Prior (α)',
        'What you believe about a die before rolling it. Jeffreys (0.5) leans '
            'towards biased dice and needs the most rolls; Flat (1) finds '
            'every bias equally plausible; Near-fair (10) trusts the die '
            'unless the rolls say otherwise. The rolls then update it.'
      ),
      (
        'Min / Shannon',
        'Min-entropy counts what an attacker who always guesses the likeliest '
            'face faces: the right measure for keys. Shannon is the average '
            'surprise and overstates a biased die.'
      ),
      (
        '≤ bound',
        'The highest chance of falling short of the target you accept.'
      ),
      (
        'Draws',
        'Monte Carlo samples behind the curve: more is smoother and slower. '
            'They are not secret and carry nothing of your rolls.'
      ),
      (
        'Custom dice',
        'Any fair process with N equally likely outcomes, numbered 1 to N: a '
            'D52 is a card drawn from a well-shuffled deck, put back and '
            'shuffled again each time.'
      ),
      (
        'What it cannot see',
        'The model assumes independent rolls. It catches a biased die, not '
            'rolls you chose or a camera over your shoulder.'
      ),
    ];
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Advanced mode'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final (String head, String body) in items) ...<Widget>[
              Text(head, style: theme.textTheme.titleSmall),
              Text(body, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The emphatic warning before finishing short of the target.
class _ShortDialog extends StatelessWidget {
  const _ShortDialog({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.warning_amber, color: scheme.error, size: 40),
      title: Text('NOT ENOUGH ENTROPY', style: TextStyle(color: scheme.error)),
      content: Text(
        '$message\n\nA key from these rolls is weaker than it looks, and this '
        'tool bears no responsibility for it. Roll more unless you know what '
        'you are doing.',
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Roll more'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Use them anyway'),
        ),
      ],
    );
  }
}

// --- background estimate -------------------------------------------------------

class _Job {
  const _Job({
    required this.rolls,
    required this.current,
    required this.settings,
    required this.generation,
  });

  final List<({int faces, List<int> rolls})> rolls;
  final int? current;
  final EstimatorSettings settings;
  final int generation;
}

class _Estimates {
  const _Estimates({
    required this.total,
    required this.perRollPrior,
    required this.perRollPosterior,
    required this.generation,
  });

  final EntropyDistribution total;
  final EntropyDistribution? perRollPrior;
  final EntropyDistribution? perRollPosterior;
  final int generation;
}

_Estimates _run(_Job job) {
  final DiceRolls rolls = DiceRolls(<DieRolls>[
    for (final ({int faces, List<int> rolls}) d in job.rolls)
      DieRolls(Die(d.faces), d.rolls),
  ]);
  final int? c = job.current;
  final DieRolls? current =
      c == null || c >= rolls.dice.length ? null : rolls.dice[c];
  final _Estimates out = _Estimates(
    total: totalEntropy(rolls, job.settings),
    perRollPrior:
        current == null ? null : perRollPrior(current.die, job.settings),
    perRollPosterior:
        current == null ? null : perRollPosterior(current, job.settings),
    generation: job.generation,
  );
  rolls.wipe();
  return out;
}
