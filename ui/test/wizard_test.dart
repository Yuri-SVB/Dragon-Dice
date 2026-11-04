import 'dart:typed_data';

import 'package:dragon_dice_ui/dragon_dice_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Readings of pseudorandom noise: a sensor that cannot fail.
class _NoiseFeed extends SensorFeed {
  static const int readings = 200;

  @override
  int get channels => 3;

  @override
  String get hint => 'Noise.';

  @override
  Future<void> start(
      ValueChanged<List<int>> onReading, ValueChanged<Object> onError) async {
    final Xoshiro256 rng = Xoshiro256(1);
    for (int i = 0; i < readings; i++) {
      onReading(<int>[for (int c = 0; c < channels; c++) rng.nextInt64()]);
    }
  }

  @override
  Future<void> stop() async {}
}

/// Longer than the capture dialog's refresh.
const Duration _kRefreshed = Duration(milliseconds: 300);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required ValueChanged<DiceRolls> onDone,
    List<String>? cues,
    Map<String, SensorFeed Function()>? feeds,
  }) async {
    tester.view.physicalSize = const Size(1000, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DragonDiceWizard(
          targetBits: 32,
          onDone: onDone,
          onCancel: () {},
          onCue: cues?.add,
          feeds: feeds,
        ),
      ),
    ));
  }

  Future<void> type(WidgetTester tester, String line) async {
    await tester.enterText(find.byType(TextField).last, line);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  testWidgets('vanilla: enough rolls of a fair D20, then Enter', (WidgetTester tester) async {
    DiceRolls? done;
    final List<String> cues = <String>[];
    await pump(tester, onDone: (DiceRolls r) => done = r, cues: cues);
    await tester.tap(find.text('D20'));
    await tester.pump();
    await type(tester, '1 2 3 4');
    expect(find.textContaining('Not enough yet'), findsOneWidget);
    await type(tester, '5 6 7 8');
    expect(find.textContaining('Ready'), findsOneWidget);
    expect(cues, contains(DiceCue.ready));
    await type(tester, ''); // Enter on an empty line finishes
    expect(done, isNotNull);
    expect(done!.canonicalJson(),
        '{"dice":[{"faces":20,"rolls":[1,2,3,4,5,6,7,8]}],"version":"dragon-dice/1"}');
  });

  testWidgets('a bad roll is refused without echoing it', (WidgetTester tester) async {
    final List<String> cues = <String>[];
    await pump(tester, onDone: (_) {}, cues: cues);
    await tester.tap(find.text('D6'));
    await tester.pump();
    await type(tester, '3 9');
    final Finder error = find.textContaining('the line was not added');
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).data, isNot(contains('9')));
    expect(cues, contains(DiceCue.badRoll));
  });

  testWidgets('short of the target: an emphatic warning first', (WidgetTester tester) async {
    DiceRolls? done;
    await pump(tester, onDone: (DiceRolls r) => done = r);
    await tester.tap(find.text('D6'));
    await tester.pump();
    await type(tester, '1 2 3');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('NOT ENOUGH ENTROPY'), findsOneWidget);
    await tester.tap(find.text('Roll more'));
    await tester.pumpAndSettle();
    expect(done, isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use them anyway'));
    await tester.pumpAndSettle();
    expect(done!.rollCount, 3);
  });

  testWidgets('no rolls: Done is off', (WidgetTester tester) async {
    await pump(tester, onDone: (_) {});
    final FilledButton done =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'));
    expect(done.onPressed, isNull);
  });

  testWidgets('advanced asks for a private screen first',
      (WidgetTester tester) async {
    await pump(tester, onDone: (_) {});
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('PRIVATE SCREEN ONLY'), findsOneWidget);
    await tester.tap(find.text('Stay vanilla'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('advanced: the estimate and its curve', (WidgetTester tester) async {
    await pump(tester, onDone: (_) {});
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The screen is private'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('D20'));
    await tester.pump();
    await type(tester, '1 2 3 4 5 6 7 8 9 10 11 12');
    // The estimate runs in a background isolate.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pump();
    expect(find.byType(EntropyChart), findsNWidgets(2));
    expect(find.textContaining('chance below target'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a capture counts toward the target and enters the JSON',
      (WidgetTester tester) async {
    DiceRolls? done;
    await pump(tester,
        onDone: (DiceRolls r) => done = r,
        feeds: <String, SensorFeed Function()>{kSourceMouse: _NoiseFeed.new});
    await tester.tap(find.text('Mouse'));
    await tester.pumpAndSettle(); // the dialog opens
    await tester.pump(_kRefreshed);
    expect(find.textContaining('${_NoiseFeed.readings} readings'), findsOneWidget);
    await tester.tap(find.text('Use it'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mouse · '), findsOneWidget);
    expect(find.textContaining('Ready'), findsOneWidget);
    await tester.tap(find.text('Done')); // no dice needed
    await tester.pumpAndSettle();
    expect(done!.rollCount, 0);
    expect(done!.system.keys, <String>[kSourceMouse]);
    expect(done!.system[kSourceMouse]!.length, kDigestBytes * 2);
  });

  testWidgets('system randomness: mixed in, not counted',
      (WidgetTester tester) async {
    DiceRolls? done;
    await pump(tester, onDone: (DiceRolls r) => done = r);
    expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
            .onPressed,
        isNull);
    await tester.tap(find.text('System randomness'));
    await tester.pump();
    expect(find.text('Total 0.0 of 32 bits'), findsOneWidget);
    await tester.tap(find.text('Done')); // something secret: allowed, warned
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use them anyway'));
    await tester.pumpAndSettle();
    expect(done!.system[kSourceRandom]!.length, kSystemRandomBytes * 2);
  });

  testWidgets('the mouse pad turns moves into readings',
      (WidgetTester tester) async {
    await pump(tester,
        onDone: (_) {},
        feeds: <String, SensorFeed Function()>{kSourceMouse: PointerFeed.new});
    await tester.tap(find.text('Mouse'));
    await tester.pumpAndSettle();
    final Offset centre = tester.getCenter(find.text('Move here'));
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: centre);
    const int moves = 100;
    final Xoshiro256 rng = Xoshiro256(2);
    const int spread = 50;
    for (int i = 1; i <= moves; i++) {
      await mouse.moveTo(
        centre +
            Offset((rng.nextInt64() % spread).toDouble(),
                (rng.nextInt64() % spread).toDouble()),
        timeStamp: Duration(microseconds: i * 997 + (rng.nextInt64() & 0xff)),
      );
    }
    await tester.pump(_kRefreshed);
    expect(find.textContaining('$moves readings'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await mouse.removePointer();
    expect(find.textContaining('Mouse · '), findsNothing);
  });

  test('the camera grid: the centre pixel of each cell, as r + g + b', () {
    const int width = 4;
    const int height = 2;
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int p = 0; p < width * height; p++) {
      rgba[p * 4] = p; // red
      rgba[p * 4 + 1] = 1; // green
      rgba[p * 4 + 2] = 2; // blue
    }
    // 2 × 1 cells: their centres are pixels (1, 1) and (3, 1).
    expect(brightnessGrid(rgba, width, height, columns: 2, rows: 1),
        <int>[5 + 3, 7 + 3]);
  });
}
