import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/security/secret_hash.dart';
import 'package:solvanta/core/settings/app_settings.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/auth/auth_repository.dart';

/// S1 — nothing usable may sit in SharedPreferences.
///
/// Offline sign-in needs a local copy of the credential and the app-lock needs
/// a local verifier; both used to be written verbatim, so a prefs dump (root,
/// `adb backup`, the app's own files dir) handed over replayable secrets.
///
/// These checks pin down the property the audit asked for: the dump contains no
/// plaintext secret, legacy installs get upgraded in place, and sign-in and
/// unlock keep working afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Declared first because AppSettings.load() only does I/O on its first call,
  // so this is the only test in this file that can observe the migration.
  test('a legacy plain PIN is migrated to a hash, and new PINs are stored hashed',
      () async {
    SharedPreferences.setMockInitialValues({
      'solvanta.lockEnabled': true,
      // Written by an older build: the PIN sat here as plain digits.
      'solvanta.lockPin': '918273',
    });

    final settings = AppSettings.instance;
    await settings.load();

    final prefs = await SharedPreferences.getInstance();
    final migrated = prefs.getString('solvanta.lockPin') ?? '';
    expect(migrated, isNot('918273'),
        reason: 'the plain PIN must be rewritten out of the file');
    expect(isHashedSecret(migrated), isTrue);
    expect(prefs.getInt('solvanta.lockPinLength'), 6);
    expect(settings.hasLockPin, isTrue);
    expect(verifySecret('918273', settings.lockPin!), isTrue,
        reason: 'the migrated PIN must still unlock');
    expect(verifySecret('918274', settings.lockPin!), isFalse);

    // A PIN chosen after the migration never reaches disk in plain form either.
    await settings.setLockPin('4821');
    final fresh = prefs.getString('solvanta.lockPin') ?? '';
    expect(fresh, isNot('4821'));
    expect(isHashedSecret(fresh), isTrue);
    expect(prefs.getInt('solvanta.lockPinLength'), 4);
    expect(verifySecret('4821', settings.lockPin!), isTrue);
    expect(verifySecret('4822', settings.lockPin!), isFalse);
  });

  test('a prefs dump holds no usable password, yet offline login still works',
      () async {
    SharedPreferences.setMockInitialValues({});

    final store = LocalStore();
    final users = await store.loadUsers(); // seeds on first read
    expect(users, isNotEmpty);

    final prefs = await SharedPreferences.getInstance();
    final dump = prefs.getString('solvanta.users_v1') ?? '';
    expect(dump, isNotEmpty);
    expect(dump, contains('v2\$'), reason: 'passwords must be stored hashed');

    for (final u in users) {
      if (u.password.isEmpty) continue;
      expect(dump.contains(u.password), isFalse,
          reason: '${u.email}: plaintext password leaked into prefs');
    }

    // The seeded demo account must still sign in against the hashed copy.
    final signedIn = await AuthRepository(store: store).login(
      email: 'kojo.owusu@school.gh',
      password: 'student123',
    );
    expect(signedIn, isNotNull, reason: 'offline sign-in must still work');
    expect(signedIn!.email, 'kojo.owusu@school.gh');
  });

  test('an install written before hashing is upgraded on first read', () async {
    SharedPreferences.setMockInitialValues({
      'solvanta.users_v1':
          '[{"id":"USR-1","name":"Legacy","email":"legacy@school.gh",'
          '"phone":"","password":"legacy-secret","role":"teacher",'
          '"schoolId":"SCH-001","classId":null,"studentIds":[]}]',
    });

    final store = LocalStore();
    final users = await store.loadUsers();
    expect(users.single.email, 'legacy@school.gh');

    final prefs = await SharedPreferences.getInstance();
    final dump = prefs.getString('solvanta.users_v1') ?? '';
    expect(dump.contains('legacy-secret'), isFalse,
        reason: 'first read must rewrite the stored password hashed');
    expect(isHashedSecret(users.single.password), isFalse,
        reason: 'the in-memory copy stays as it was; only disk is upgraded');

    // Read the password field straight back out of the encoded blob, so this
    // asserts against what is actually on disk rather than the model's view.
    final stored = jsonDecode(dump) as List<dynamic>;
    final storedPassword =
        (stored.single as Map<String, dynamic>)['password'] as String;
    expect(isHashedSecret(storedPassword), isTrue);
    expect(verifySecret('legacy-secret', storedPassword), isTrue,
        reason: 'the upgraded verifier must still accept the real password');

    // Signing in still works after the rewrite.
    final signedIn = await AuthRepository(store: store)
        .login(email: 'legacy@school.gh', password: 'legacy-secret');
    expect(signedIn, isNotNull);
  });
}
