
import 'package:dragon_dice_ui/dragon_dice_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const DragonDiceApp());

/// The default mnemonic length: 24 words, 256 bits.
const int _kDefaultWords = 24;

/// Hex digits in a SHA-512 digest.
const int _kDigestHexDigits = 128;

class DragonDiceApp extends StatelessWidget {
  const DragonDiceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Dragon Dice',
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
        home: const _Home(),
      );
}

enum _Stage { choose, roll, result, fromDigest }

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  _Stage _stage = _Stage.choose;
  int _words = _kDefaultWords;
  Uint8List? _digest;
  bool _revealed = false;
  final TextEditingController _digestField = TextEditingController();
  String? _digestError;

  int get _entropyBits =>
      kBip39EntropyBits.firstWhere((int b) => bip39Words(b) == _words);

  @override
  void dispose() {
    _forget();
    _digestField.dispose();
    super.dispose();
  }

  /// Wipe the digest in hand.
  void _forget() {
    final Uint8List? d = _digest;
    if (d != null) d.fillRange(0, d.length, 0);
    _digest = null;
    _revealed = false;
  }

  void _restart() {
    setState(() {
      _forget();
      _digestField.clear();
      _digestError = null;
      _stage = _Stage.choose;
    });
  }

  void _rolled(DiceRolls rolls) {
    final Uint8List digest = rolls.digest();
    rolls.wipe();
    setState(() {
      _digest = digest;
      _stage = _Stage.result;
    });
  }

  void _fromDigest() {
    final String hex = _digestField.text.trim();
    if (!RegExp('^[0-9a-fA-F]{$_kDigestHexDigits}\$').hasMatch(hex)) {
      setState(() => _digestError = 'A SHA-512 digest is $_kDigestHexDigits hex digits.');
      return;
    }
    _digestField.clear();
    setState(() {
      _digest = Uint8List.fromList(<int>[
        for (int i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      _digestError = null;
      _stage = _Stage.result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: switch (_stage) {
          _Stage.choose => _choose(context),
          _Stage.roll => DragonDiceWizard(
              targetBits: _entropyBits.toDouble(),
              purpose: 'A $_words-word BIP39 mnemonic',
              onDone: _rolled,
              onCancel: _restart,
            ),
          _Stage.result => _result(context),
          _Stage.fromDigest => _digestEntry(context),
        },
      ),
    );
  }

  Widget _choose(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Dragon Dice', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            const Text(
              'Entropy from real dice that anyone can audit: your rolls become '
              'a JSON whose SHA-512 is the secret, and its first bits a BIP39 '
              'mnemonic. Do this offline, where no one and no camera can see.',
            ),
            const SizedBox(height: 24),
            Text('Mnemonic length', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: <ButtonSegment<int>>[
                for (final int b in kBip39EntropyBits)
                  ButtonSegment<int>(
                    value: bip39Words(b),
                    label: Text('${bip39Words(b)} words'),
                  ),
              ],
              selected: <int>{_words},
              onSelectionChanged: (Set<int> s) => setState(() => _words = s.first),
            ),
            const SizedBox(height: 4),
            Text('$_entropyBits bits: the target your rolls must reach.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => setState(() => _stage = _Stage.roll),
              icon: const Icon(Icons.casino),
              label: const Text('Roll dice'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => setState(() => _stage = _Stage.fromDigest),
              child: const Text('From a digest I already have'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _digestEntry(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('BIP39 from a SHA-512 digest',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _digestField,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Digest ($_kDigestHexDigits hex digits, hidden)',
                errorText: _digestError,
              ),
              onSubmitted: (_) => _fromDigest(),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(onPressed: _restart, child: const Text('Back')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _fromDigest, child: const Text('To words')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Uint8List digest = _digest!;
    final String words = bip39FromDigest(digest, entropyBits: _entropyBits);
    final String hex =
        digest.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    Future<void> copy(String text, String what) async {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$what copied. The clipboard is not private: clear it '
            'once pasted.'),
      ));
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Secret', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              'Write the words down offline. Anyone who sees them, or the '
              'digest, has the key.',
            ),
            const SizedBox(height: 16),
            Text('BIP39 ($_words words)', style: theme.textTheme.titleMedium),
            SelectableText(
              _revealed ? words : '•••• ' * _words,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 18),
            ),
            const SizedBox(height: 12),
            Text('SHA-512 of the rolls', style: theme.textTheme.titleMedium),
            SelectableText(
              _revealed ? hex : '•' * _kDigestHexDigits,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
                  label: Text(_revealed ? 'Hide' : 'Reveal'),
                ),
                OutlinedButton(
                  onPressed: () => copy(words, 'Words'),
                  child: const Text('Copy words'),
                ),
                OutlinedButton(
                  onPressed: () => copy(hex, 'Digest'),
                  child: const Text('Copy digest'),
                ),
                TextButton(
                  onPressed: _restart,
                  child: const Text('Forget and start over'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
