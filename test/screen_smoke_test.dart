import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/models/user.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/home/dashboards.dart';

/// Opens every role's dashboard and every module it can reach, at each
/// responsive width class, on the seeded offline data. Fails on any build or
/// layout error (unbounded grids, overflows, missing builders), so a screen
/// that silently stops showing its data at some width can't ship.
///
/// Widths: phone, small tablet / phone landscape, tablet, large tablet,
/// desktop, large desktop.
const _widths = <double>[390, 700, 900, 1100, 1440, 1920];

const _accounts = <(String, String)>[
  ('admin@solvanta.app', 'admin123'),
  ('head@school.gh', 'head123'),
  ('efua.mensah@school.gh', 'teacher123'),
  ('ama.owusu@school.gh', 'parent123'),
  ('kojo.owusu@school.gh', 'student123'),
  ('staff.smoke@school.gh', 'staff123'),
];

/// The seed has no staff account, so add one for the staff dashboard.
Future<void> _addStaffUser() async {
  final store = LocalStore();
  final users = await store.loadUsers();
  await store.saveUsers([
    ...users,
    User(
      id: 'U-STAFF-SMOKE',
      name: 'Smoke Staff',
      email: 'staff.smoke@school.gh',
      phone: '0200000000',
      password: 'staff123',
      role: AppRole.staff,
      schoolId: users.first.schoolId,
    ),
  ]);
}

Future<void> _show(WidgetTester tester, double width, Widget home) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: home));
  // Some repositories need real async time (storage hops) to resolve, and
  // entrance animations and spinners never settle, so interleave short real
  // waits with fixed frames instead of pumpAndSettle.
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// The next error a frame reported, skipping platform-plugin calls that have
/// no implementation in a plain widget test (they do on a device / the web).
Object? _uiError(WidgetTester tester) {
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {
    if (e is! MissingPluginException) return e;
  }
  return null;
}

void main() {
  for (final (email, password) in _accounts) {
    testWidgets('$email: dashboard and every module render at all widths',
        (tester) async {
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final user = await tester.runAsync(() async {
        await _addStaffUser();
        return AuthRepository().login(email: email, password: password);
      });
      expect(user, isNotNull, reason: 'demo login for $email');

      for (final width in _widths) {
        await _show(tester, width, dashboardFor(user!));
        expect(_uiError(tester), isNull,
            reason: 'dashboard for $email at ${width}px');

        for (final module in modulesFor(user.role)) {
          final builder = module.builder;
          if (builder == null) continue;
          await _show(tester, width, Builder(builder: builder));
          expect(_uiError(tester), isNull,
              reason: '${module.label} for $email at ${width}px');
        }
      }
      // Drop the last screen so its timers are disposed inside the test.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
