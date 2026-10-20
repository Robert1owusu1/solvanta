import '../../core/api/api_client.dart';
import '../../core/api/remote_data_source.dart';
import '../../core/models/role.dart';
import '../../core/models/user.dart';
import '../../core/security/secret_hash.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

/// Authenticates against the local seed store by default. When an API endpoint
/// is configured (`--dart-define=SOLVANTA_API=<url>` or `SOLVANTA_API_URL`),
/// `login` authenticates against the live backend instead; the returned user is
/// then mirrored into the local store so the rest of the app (dashboards,
/// repositories) keeps working with the app's usual offline data flow.
class AuthRepository {
  AuthRepository({LocalStore? store, RemoteDataSource? remote})
      : _store = store ?? LocalStore(),
        _remote = remote ??
            (ApiClient.isConfigured ? RemoteDataSource() : null);

  final LocalStore _store;
  final RemoteDataSource? _remote;

  bool get remoteEnabled => _remote != null;

  Future<User?> login({
    required String email,
    required String password,
  }) async {
    final remote = _remote;
    if (remote != null) {
      final res = await remote.login(email: email, password: password);
      final remoteUser = res.user;

      final users = await _store.loadUsers();
      User? existing;
      for (final u in users) {
        if (u.id == remoteUser.id) existing = u;
      }
      // The API never returns plaintext passwords, so keep the local one for
      // offline logins; mirror every other attribute from the server.
      final user = User(
        id: remoteUser.id,
        name: remoteUser.name,
        email: remoteUser.email,
        phone: remoteUser.phone,
        password: existing?.password ?? '',
        role: remoteUser.role,
        schoolId: remoteUser.schoolId,
        classId: remoteUser.classId,
        studentIds: remoteUser.studentIds,
      );
      final merged = [...users.where((u) => u.id != user.id), user];
      await _store.saveUsers(merged);
      await _store.setSessionUser(user.id);
      // Persist the bearer token too. `remote.login` already published it to
      // `ApiClient.sharedToken`, but that static dies with the process while
      // the session id above does not. Persisting only the session is what
      // made a cold start silently unauthenticated: signed in, 401 on every
      // write, and offline-first fallbacks hiding it behind local data.
      await _store.setApiToken(res.token);
      // Fill the device with this account's data before the dashboard opens
      // (bounded, so a slow network still lets the user in on local data).
      ServerSync.instance.start();
      await ServerSync.instance
          .pull()
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      return user;
    }

    final users = await _store.loadUsers();
    for (final u in users) {
      if (u.email.toLowerCase() == email.trim().toLowerCase() &&
          // The stored copy is a hash; verifySecret still accepts a legacy
          // plain value so an install that predates hashing can sign in, and
          // LocalStore.loadUsers rewrites it hashed on that first read.
          verifySecret(password, u.password)) {
        await _store.setSessionUser(u.id);
        return u;
      }
    }
    return null;
  }

  Future<User?> register({
    required String name,
    required String email,
    required String phone,
    required String password,
    required AppRole role,
  }) async {
    final users = await _store.loadUsers();
    final exists = users.any((u) =>
        u.email.toLowerCase() == email.trim().toLowerCase());
    if (exists) return null;

    // `length + 1` alone collides once any account has been removed or ids
    // were assigned elsewhere; take the first number nobody holds yet.
    final taken = users.map((u) => u.id).toSet();
    var n = users.length + 1;
    while (taken.contains('USR-$n')) {
      n++;
    }
    final user = User(
      id: 'USR-$n',
      name: name.trim(),
      email: email.trim(),
      phone: phone.trim(),
      password: hashSecret(password), // Store hashed from the start
      role: role,
      schoolId: 'SCH-001',
    );
    users.add(user);
    await _store.saveUsers(users);
    await _store.setSessionUser(user.id);
    return user;
  }

  Future<User?> currentUser() async {
    final id = await _store.getSessionUserId();
    if (id == null) return null;
    final users = await _store.loadUsers();
    for (final u in users) {
      if (u.id == id) return u;
    }
    return null;
  }

  Future<void> logout() async {
    ServerSync.instance.stop();
    final remote = _remote;
    if (remote != null) {
      try {
        await remote.logout();
      } on ApiException {
        // Best-effort server-side revocation; the session must still end
        // locally even if the token was already invalid.
      }
    }
    await _store.clearSession();
    // Drop the bearer token with the session, otherwise the next account that
    // signs in on this device starts out presenting the previous one's token
    // (401, then a silent local-only write until a fresh login replaces it).
    await _store.setApiToken(null);
  }
}