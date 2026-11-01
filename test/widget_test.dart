import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synapmentor/main.dart';

const _screen = Size(390, 844);

Future<void> pumpApp(WidgetTester tester) async {
  tester.view
    ..physicalSize = _screen
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SynapMentorApp());
}

Future<void> advance(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

void main() {
  testWidgets('splash holds for 3 seconds, then reveals the welcome card', (tester) async {
    await pumpApp(tester);
    await advance(tester, const Duration(milliseconds: 2800));

    expect(find.text('SYNAP MENTOR'), findsOneWidget);
    // The welcome card is built from the start but parked below the screen.
    final welcome = find.text('WELCOME');
    expect(tester.getTopLeft(welcome).dy, greaterThan(_screen.height), reason: 'still on splash before 3s');

    await advance(tester, const Duration(milliseconds: 1400));
    expect(tester.getTopLeft(welcome).dy, lessThan(_screen.height));
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Sign Up'), findsOneWidget);
  });

  testWidgets('sign in screen switches between login methods', (tester) async {
    await pumpApp(tester);
    await advance(tester, const Duration(milliseconds: 5200));

    await tester.tap(find.text('Sign In'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Forgot Password?'), findsOneWidget);

    await tester.tap(find.text('OTP'));
    await advance(tester, const Duration(milliseconds: 400));
    expect(find.text('Send OTP'), findsOneWidget);

    await tester.tap(find.text('Magic Link'));
    await advance(tester, const Duration(milliseconds: 400));
    expect(find.text('Send Magic Link'), findsOneWidget);

    await tester.tap(find.text('Backup Code'));
    await advance(tester, const Duration(milliseconds: 400));
    expect(find.widgetWithText(TextField, 'Backup code'), findsOneWidget);
  });
}
