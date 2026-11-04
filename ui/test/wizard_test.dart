import 'package:dragon_dice_ui/dragon_dice_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required ValueChanged<DiceRolls> onDone,
    List<String>? cues,
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
        '{"dice":[{"faces":20,"rolls":[1,2,3,4,5,6,7,8]}],"format":"dragon-dice/1"}');
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

  testWidgets('advanced: the estimate and its curve', (WidgetTester tester) async {
    await pump(tester, onDone: (_) {});
    await tester.tap(find.byType(Switch));
    await tester.pump();
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
}
