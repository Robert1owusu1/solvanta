import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the sign-in screen when no session exists', (tester) async {
    await tester.pumpWidget(const SolvantaApp());
    await tester.pumpAndSettle();

    expect(find.text('SOLVANTA'), findsWidgets);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('logs in with a seeded demo account', (tester) async {
    await tester.pumpWidget(const SolvantaApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome, Ms.'), findsOneWidget);
    expect(find.text('Teacher'), findsOneWidget);
  });
}