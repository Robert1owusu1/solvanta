import '../../core/api/api_client.dart';
import '../../core/api/remote_data_source.dart';
import '../../core/models/role.dart';
import '../../core/models/user.dart';
import '../../core/storage/local_store.dart';

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
      return user;
    }

    final users = await _store.loadUsers();
    for (final u in users) {
      if (u.email.toLowerCase() == email.trim().toLowerCase() &&
          u.password == password) {
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

    final user = User(
      id: 'USR-${users.length + 1}',
      name: name.trim(),
      email: email.trim(),
      phone: phone.trim(),
      password: password,
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
  }
}