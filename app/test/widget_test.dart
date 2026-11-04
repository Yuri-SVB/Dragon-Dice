import 'package:dragon_dice_app/main.dart';
import 'package:dragon_dice_ui/dragon_dice_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const DragonDiceApp());
  }

  testWidgets('roll for 12 words, then reveal them', (WidgetTester tester) async {
    await start(tester);
    await tester.tap(find.text('12 words'));
    await tester.pump();
    await tester.tap(find.text('Roll dice'));
    await tester.pumpAndSettle();
    expect(find.byType(DragonDiceWizard), findsOneWidget);
    await tester.tap(find.text('D20'));
    await tester.pump();
    // 30 D20 rolls: 129.7 bits if fair, past 128.
    final List<int> rolls = <int>[for (int i = 0; i < 30; i++) i % 20 + 1];
    await tester.enterText(find.byType(TextField).last, rolls.join(' '));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsOneWidget);
    await tester.tap(find.text('Reveal'));
    await tester.pump();
    final DiceRolls expected = DiceRolls(<DieRolls>[DieRolls(Die(20), rolls)]);
    expect(find.text(bip39FromDigest(expected.digest(), entropyBits: 128)),
        findsOneWidget);
  });

  testWidgets('from a digest: the reference zero vector', (WidgetTester tester) async {
    await start(tester);
    await tester.tap(find.text('12 words'));
    await tester.pump();
    await tester.tap(find.text('From a digest I already have'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0' * 128);
    await tester.tap(find.text('To words'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reveal'));
    await tester.pump();
    expect(
        find.text('abandon abandon abandon abandon abandon abandon abandon '
            'abandon abandon abandon abandon about'),
        findsOneWidget);
  });
}
