import 'package:flutter_test/flutter_test.dart';

import 'package:aim_trainer/main.dart';

void main() {
  testWidgets('menu renders and a round can start', (tester) async {
    await tester.pumpWidget(const AimTrainerApp());
    await tester.pump();

    expect(find.text('AIM TRAINER'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);

    await tester.tap(find.text('START'));
    await tester.pump();

    // Countdown is rendered by the game painter; menu UI should be gone.
    expect(find.text('START'), findsNothing);
    expect(find.byType(GameScreen), findsOneWidget);

    // Let the ticker run briefly, then make sure teardown is clean.
    await tester.pump(const Duration(milliseconds: 500));
  });
}
