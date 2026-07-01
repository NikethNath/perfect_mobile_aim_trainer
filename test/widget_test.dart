import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aim_trainer/main.dart';

void main() {
  testWidgets('menu -> play -> round starts', (tester) async {
    await tester.pumpWidget(const AimTrainerApp());
    await tester.pump();

    expect(find.text('AIM RANKED'), findsOneWidget);
    expect(find.text('PLAY'), findsOneWidget);

    // Open the Play screen, then start the first scenario.
    await tester.tap(find.text('PLAY'));
    await tester.pump();
    expect(find.text('CUBES'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await tester.pump();
    expect(find.byType(GameScreen), findsOneWidget);

    // Let the ticker run briefly, then make sure teardown is clean.
    await tester.pump(const Duration(milliseconds: 500));
  });

  test('rank thresholds are strictly ascending', () {
    for (int i = 1; i < kRanks.length; i++) {
      expect(kRanks[i].threshold, greaterThan(kRanks[i - 1].threshold));
    }
  });

  test('every tuning param has a default', () {
    for (final TuneParam p in kTuneParams) {
      expect(kTuneDefaults[p.key], p.def);
      expect(p.def, inInclusiveRange(p.min, p.max));
    }
  });

  test('every scenario has a description and a score scale', () {
    expect(kScenarioDesc.length, kScenarios.length);
    expect(kScoreScale.length, kScenarios.length);
  });

  test('tuningIsDefault gates on the scenario defaults', () {
    // A fresh copy of the defaults ranks for every scenario, including the
    // modes that expose no tunable params (CUBES, BARDPILL).
    final Map<String, double> tune = Map<String, double>.from(kTuneDefaults);
    for (int s = 0; s < kScenarios.length; s++) {
      expect(tuningIsDefault(s, tune), isTrue);
    }

    // Nudging one FLOAT (scenario 1) param off default un-ranks only FLOAT.
    tune['fl_orbit'] = kTuneDefaults['fl_orbit']! + 0.5;
    expect(tuningIsDefault(1, tune), isFalse);
    expect(tuningIsDefault(2, tune), isTrue); // REACTIVE untouched
  });
}
