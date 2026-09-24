import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/app.dart';
import 'package:solvanta/features/security/lock_screen.dart';

/// Regression for the on-device observation "lockEnabled=true on disk but a
/// cold start lands straight on Home": proves the engage path (AppSettings
/// fire-and-forget load → notifyListeners → AppLockGate._evaluateInitial →
/// cover) actually shows LockScreen for a signed-in cold start.
///
/// Bounded pumps instead of pumpAndSettle: the settings future lands between
/// frames and the cover fades in over 320 ms, and any looping animation inside
/// LockScreen (biometric "Checking…") would make Settle time out.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'solvanta.session_user_id': 'USR-TCH-001',
      'solvanta.lockEnabled': true,
      'solvanta.lockMethod': 'pin',
      'solvanta.lockPin': '123456',
    });
  });

  testWidgets('cold start with the lock enabled covers the app', (tester) async {
    await tester.pumpWidget(const SolvantaApp());
    await tester.pump(); // first frame; prefs future scheduled
    await tester.pump(const Duration(milliseconds: 120)); // load() → notify → _showLock
    await tester.pump(const Duration(milliseconds: 400)); // cover fade-in

    expect(find.byType(LockScreen), findsOneWidget);
  });
}
