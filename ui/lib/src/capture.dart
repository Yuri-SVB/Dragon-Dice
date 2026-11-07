import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dragon_dice/dragon_dice.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// The names shown for the sources.
const Map<String, String> kSourceLabels = <String, String>{
  kSourceAccelerometer: 'Accelerometer',
  kSourceCamera: 'Camera',
  kSourceMouse: 'Mouse',
  kSourceRandom: 'System randomness',
};

/// A finished capture: its digest, which enters the rolls JSON, and its
/// credit.
typedef Capture = ({String digestHex, SensorCredit credit});

/// A peripheral that streams readings of a fixed number of integer channels.
abstract class SensorFeed {
  /// Values per reading.
  int get channels;

  /// The channel holding each reading's time in microseconds, if any: not
  /// credited, and at most one reading counted per
  /// [kMinReadingIntervalUs].
  int? get timeChannel => null;

  /// The move a reading needs to be counted: some value changed by at least
  /// this much since the last counted reading ([sensorCredit]).
  int get minStep => 0;

  /// What to do while it captures.
  String get hint;

  /// Start reading: each reading goes to [onReading], a failure (no such
  /// device, permission refused) to [onError].
  Future<void> start(
      ValueChanged<List<int>> onReading, ValueChanged<Object> onError);

  Future<void> stop();

  /// Where the readings are made on screen (the mouse's pad); null for a
  /// device.
  Widget? pad(BuildContext context) => null;
}

/// The peripheral sources this platform may have, by source name. A device
/// may still lack one; its capture then says so.
Map<String, SensorFeed Function()> platformFeeds() {
  final Map<String, SensorFeed Function()> feeds =
      <String, SensorFeed Function()>{kSourceMouse: PointerFeed.new};
  if (kIsWeb) return feeds;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      feeds[kSourceAccelerometer] = AccelerometerFeed.new;
      feeds[kSourceCamera] = CameraFeed.new;
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      feeds[kSourceCamera] = CameraFeed.new;
    case TargetPlatform.fuchsia:
      break;
  }
  return feeds;
}

// --- mouse ---------------------------------------------------------------------

/// The pointer's move a reading needs to be counted, in physical pixels: a
/// real move, not a wiggle.
const int kMouseMinStepPx = 8;

/// The mouse, or a finger, over a pad: each move is a reading of its position
/// in physical pixels and its time in microseconds.
class PointerFeed extends SensorFeed {
  ValueChanged<List<int>>? _onReading;

  /// x, y, time.
  @override
  int get channels => 3;

  @override
  int get timeChannel => 2;

  @override
  int get minStep => kMouseMinStepPx;

  @override
  String get hint => 'Move the mouse, or a finger, over the pad, erratically, '
      'until the credit is what you want.';

  @override
  Future<void> start(
      ValueChanged<List<int>> onReading, ValueChanged<Object> onError) async {
    _onReading = onReading;
  }

  @override
  Future<void> stop() async => _onReading = null;

  @override
  Widget pad(BuildContext context) {
    final double ratio = MediaQuery.devicePixelRatioOf(context);
    void move(PointerEvent e) => _onReading?.call(<int>[
          (e.position.dx * ratio).round(),
          (e.position.dy * ratio).round(),
          e.timeStamp.inMicroseconds,
        ]);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerHover: move,
      onPointerMove: move,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.outline),
        ),
        child: const Center(child: Text('Move here')),
      ),
    );
  }
}

// --- accelerometer -------------------------------------------------------------

/// Fixed point for the accelerometer's m/s²: 16 fractional bits.
const double _kAccelerometerScale = 65536;

/// The change of acceleration a reading needs to be counted, in m/s²: a
/// shake or a tap, not the sensor's noise at rest.
const double _kAccelerometerMinStep = 0.5;

/// The accelerometer, as fast as it reports: x, y, z in fixed point and the
/// time in microseconds.
class AccelerometerFeed extends SensorFeed {
  StreamSubscription<AccelerometerEvent>? _subscription;

  /// x, y, z, time.
  @override
  int get channels => 4;

  @override
  int get timeChannel => 3;

  @override
  int get minStep => (_kAccelerometerMinStep * _kAccelerometerScale).round();

  @override
  String get hint => 'Shake or tap the device, irregularly, until the credit '
      'is what you want.';

  @override
  Future<void> start(
      ValueChanged<List<int>> onReading, ValueChanged<Object> onError) async {
    _subscription = accelerometerEventStream(
      samplingPeriod: SensorInterval.fastestInterval,
    ).listen(
      (AccelerometerEvent e) => onReading(<int>[
        (e.x * _kAccelerometerScale).round(),
        (e.y * _kAccelerometerScale).round(),
        (e.z * _kAccelerometerScale).round(),
        e.timestamp.microsecondsSinceEpoch,
      ]),
      onError: onError,
    );
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

// --- camera --------------------------------------------------------------------

/// The camera's grid: columns × rows of pixels, read every frame.
const int kCameraColumns = 16;
const int kCameraRows = 12;

/// Bytes per pixel in a raw RGBA image.
const int _kRgbaBytes = 4;

/// The brightness (red + green + blue) of a [columns] × [rows] grid of pixels,
/// each at the centre of its cell, of a [width] × [height] RGBA image, row by
/// row.
List<int> brightnessGrid(
  Uint8List rgba,
  int width,
  int height, {
  int columns = kCameraColumns,
  int rows = kCameraRows,
}) {
  // The centre of cell i of n over size pixels.
  int centre(int i, int n, int size) => (2 * i + 1) * size ~/ (2 * n);
  return <int>[
    for (int r = 0; r < rows; r++)
      for (int c = 0; c < columns; c++)
        () {
          final int at = (centre(r, rows, height) * width +
                  centre(c, columns, width)) *
              _kRgbaBytes;
          return rgba[at] + rgba[at + 1] + rgba[at + 2];
        }(),
  ];
}

/// The change of a grid pixel's brightness (red + green + blue) a frame
/// needs to be counted: a new frame, not the same one again.
const int _kCameraMinStep = 8;

/// The camera, frame after frame: each frame's [brightnessGrid], then its
/// time in microseconds, is a reading. Its noise is what is credited.
class CameraFeed extends SensorFeed {
  MediaStream? _stream;
  bool _running = false;

  /// The grid's pixels, then the time.
  @override
  int get channels => kCameraColumns * kCameraRows + 1;

  @override
  int get timeChannel => kCameraColumns * kCameraRows;

  @override
  int get minStep => _kCameraMinStep;

  @override
  String get hint => 'Point the camera at anything not black and not blown '
      'out: its noise is what counts. Hold on until the credit is what you '
      'want.';

  @override
  Future<void> start(
      ValueChanged<List<int>> onReading, ValueChanged<Object> onError) async {
    try {
      final MediaStream stream =
          await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': false,
        // Plain true: a facing-mode constraint can fail on desktops.
        'video': true,
      });
      _stream = stream;
      _running = true;
      unawaited(_loop(stream.getVideoTracks().first, onReading, onError));
    } catch (e) {
      onError(e);
    }
  }

  Future<void> _loop(MediaStreamTrack track, ValueChanged<List<int>> onReading,
      ValueChanged<Object> onError) async {
    while (_running) {
      try {
        final List<int> grid = await _grid(await track.captureFrame());
        if (_running) {
          onReading(<int>[...grid, DateTime.now().microsecondsSinceEpoch]);
        }
      } catch (e) {
        if (_running) onError(e);
        return;
      }
    }
  }

  static Future<List<int>> _grid(ByteBuffer frame) async {
    final ui.Codec codec = await ui.instantiateImageCodec(frame.asUint8List());
    final ui.Image image = (await codec.getNextFrame()).image;
    try {
      final ByteData? rgba =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) throw StateError('the frame did not decode');
      final Uint8List bytes = rgba.buffer.asUint8List();
      final List<int> grid = brightnessGrid(bytes, image.width, image.height);
      bytes.fillRange(0, bytes.length, 0);
      return grid;
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    final MediaStream? stream = _stream;
    _stream = null;
    if (stream == null) return;
    for (final MediaStreamTrack t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }
}

// --- the capture dialog --------------------------------------------------------

/// How often the dialog recomputes the credit.
const Duration _kRefresh = Duration(milliseconds: 250);

/// Width of the capture dialog, in logical pixels.
const double _kCaptureWidth = 420;

/// Height of the mouse's pad, in logical pixels.
const double _kPadHeight = 220;

/// Capture [feed] until the user stops it; null if cancelled. The readings
/// are wiped either way.
Future<Capture?> captureSource(
  BuildContext context, {
  required String title,
  required SensorFeed feed,
}) =>
    showDialog<Capture>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => _CaptureDialog(title: title, feed: feed),
    );

class _CaptureDialog extends StatefulWidget {
  const _CaptureDialog({required this.title, required this.feed});

  final String title;
  final SensorFeed feed;

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  late final SensorCapture _capture = SensorCapture(
    widget.feed.channels,
    timeChannel: widget.feed.timeChannel,
    minStep: widget.feed.minStep,
  );
  SensorCredit _credit = sensorCredit(const <List<int>>[]);
  Timer? _refresh;
  String? _error;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.feed.start(_reading, _failed);
    _refresh = Timer.periodic(_kRefresh, (Timer _) => _update());
  }

  void _reading(List<int> reading) {
    if (!_closed) _capture.add(reading);
  }

  void _failed(Object e) {
    if (!mounted || _closed) return;
    setState(() => _error = 'The ${widget.title.toLowerCase()} is not '
        'available here (${e.runtimeType}).');
  }

  void _update() {
    if (mounted && !_closed) setState(() => _credit = _capture.credit());
  }

  Future<void> _finish(bool keep) async {
    _closed = true;
    _refresh?.cancel();
    await widget.feed.stop();
    final Capture? out = keep
        ? (digestHex: _capture.digestHex(), credit: _capture.credit())
        : null;
    _capture.wipe();
    if (mounted) Navigator.of(context).pop(out);
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      _refresh?.cancel();
      widget.feed.stop();
      _capture.wipe();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget? pad = widget.feed.pad(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: _kCaptureWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(widget.feed.hint, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (pad != null) ...<Widget>[
              SizedBox(height: _kPadHeight, child: pad),
              const SizedBox(height: 12),
            ],
            Text(
              '${_capture.length} readings · '
              '${_credit.bits.toStringAsFixed(1)} bits credited',
              style: theme.textTheme.titleMedium,
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => _finish(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _capture.length == 0 ? null : () => _finish(true),
          child: const Text('Use it'),
        ),
      ],
    );
  }
}
