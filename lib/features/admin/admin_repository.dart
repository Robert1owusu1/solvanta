import 'dart:convert';

import '../../core/models/class_room.dart';
import '../../core/models/role.dart';
import '../../core/models/school.dart';
import '../../core/models/user.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

class AdminRepository {
  AdminRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<School?> school() => _store.loadSchool();

  Future<void> saveSchool(School school) async {
    await _store.saveSchool(school);
    await ServerSync.instance.send('PUT', '/api/school', body: school.toJson());
  }

  Future<List<ClassRoom>> classes() => _store.loadClasses();

  /// Saves the class list, sending each new or changed class to the server.
  /// Use [deleteClass] to remove one.
  Future<void> saveClasses(List<ClassRoom> classes) async {
    final before = {for (final c in await _store.loadClasses()) c.id: c};
    await _store.saveClasses(classes);
    for (final c in classes) {
      final old = before[c.id];
      if (old != null && jsonEncode(old) == jsonEncode(c)) continue;
      await ServerSync.instance
          .send('PUT', '/api/school/classes/${c.id}', body: c.toJson());
    }
  }

  /// Removes a class that has no students. Returns why it can't be removed,
  /// or null once it is gone.
  Future<String?> deleteClass(String id) async {
    final students = await _store.loadStudents();
    if (students.any((s) => s.classId == id && s.status == 'Active')) {
      return 'This class still has students. Move them to another class first.';
    }
    final classes = await _store.loadClasses();
    await _store.saveClasses(classes.where((c) => c.id != id).toList());
    await ServerSync.instance.send('DELETE', '/api/school/classes/$id');
    return null;
  }

  Future<List<User>> users() => _store.loadUsers();

  Future<List<User>> staffList() async {
    final all = await _store.loadUsers();
    return all
        .where((u) =>
            u.role == AppRole.teacher ||
            u.role == AppRole.staff ||
            u.role == AppRole.headteacher ||
            u.role == AppRole.schoolAdmin)
        .toList();
  }

  Future<List<User>> parentUsers() async {
    final all = await _store.loadUsers();
    return all.where((u) => u.role == AppRole.parent).toList();
  }

  /// A fresh local id. Time-based, so it can't collide with an existing
  /// account the way a count-based id could after a removal; the server
  /// assigns its own id when the account syncs.
  String nextUserId(List<User> users) =>
      'USR-${DateTime.now().millisecondsSinceEpoch}';

  /// Creates or updates an account. [user.password] is the plain password
  /// for a new account (or a changed one), otherwise the stored hash.
  Future<void> addOrUpdateUser(User user) async {
    final all = await _store.loadUsers();
    final list = <User>[];
    var existed = false;
    for (final u in all) {
      if (u.id == user.id) {
        list.add(user);
        existed = true;
      } else {
        list.add(u);
      }
    }
    if (!existed) list.add(user);
    await _store.saveUsers(list);

    if (existed) {
      await _syncUser(user);
      return;
    }
    final saved = await ServerSync.instance.sendFor('POST', '/api/users', {
      'name': user.name,
      'email': user.email,
      'phone': user.phone,
      'password': user.password,
      'role': user.role.name,
      'classId': user.classId ?? '',
      'studentIds': user.studentIds,
    }, User.fromJson);
    if (saved == null) return;
    // Keep the local (hashed) password so the account can also sign in
    // offline on this device; take everything else from the server.
    final stored = (await _store.loadUsers())
        .firstWhere((u) => u.id == user.id, orElse: () => user);
    final now = await _store.loadUsers();
    await _store.saveUsers([
      for (final u in now)
        if (u.id == user.id)
          User(
            id: saved.id,
            name: saved.name,
            email: saved.email,
            phone: saved.phone,
            password: stored.password,
            role: saved.role,
            schoolId: saved.schoolId,
            classId: saved.classId,
            studentIds: saved.studentIds,
          )
        else
          u,
    ]);
  }

  Future<void> _syncUser(User u) => ServerSync.instance.send(
        'PATCH',
        '/api/users/${u.id}',
        body: {
          'name': u.name,
          'phone': u.phone,
          'role': u.role.name,
          'classId': u.classId ?? '',
          'studentIds': u.studentIds,
        },
      );

  Future<void> linkParentToStudent({
    required String parentUserId,
    required String studentId,
  }) async {
    final users = await _store.loadUsers();
    final students = await _store.loadStudents();
    final updatedUsers = users.map((u) {
      if (u.id != parentUserId) return u;
      final ids = u.studentIds.contains(studentId)
          ? u.studentIds
          : [...u.studentIds, studentId];
      return _userWithStudentIds(u, ids);
    }).toList();
    final updatedStudents = students.map((s) {
      if (s.id != studentId) return s;
      return s.copyWith(parentUserId: parentUserId);
    }).toList();
    await _store.saveUsers(updatedUsers);
    await _store.saveStudents(updatedStudents);
    await _syncLink(parentUserId, studentId, updatedUsers, linked: true);
  }

  Future<void> unlinkParentFromStudent({
    required String parentUserId,
    required String studentId,
  }) async {
    final users = await _store.loadUsers();
    final students = await _store.loadStudents();
    final updatedUsers = users.map((u) {
      if (u.id != parentUserId) return u;
      return _userWithStudentIds(
          u, u.studentIds.where((id) => id != studentId).toList());
    }).toList();
    final updatedStudents = students.map((s) {
      if (s.id != studentId || s.parentUserId != parentUserId) return s;
      return s.copyWith(parentUserId: null);
    }).toList();
    await _store.saveUsers(updatedUsers);
    await _store.saveStudents(updatedStudents);
    await _syncLink(parentUserId, studentId, updatedUsers, linked: false);
  }

  /// The link lives on both sides: the parent's studentIds and the
  /// student's parentUserId.
  Future<void> _syncLink(String parentUserId, String studentId,
      List<User> users, {required bool linked}) async {
    final parent = users.where((u) => u.id == parentUserId).firstOrNull;
    if (parent != null) {
      await ServerSync.instance.send('PATCH', '/api/users/$parentUserId',
          body: {'studentIds': parent.studentIds});
    }
    await ServerSync.instance.send('PATCH', '/api/students/$studentId',
        body: {'parentUserId': linked ? parentUserId : ''});
  }

  User _userWithStudentIds(User u, List<String> ids) => User(
        id: u.id,
        name: u.name,
        email: u.email,
        phone: u.phone,
        password: u.password,
        role: u.role,
        schoolId: u.schoolId,
        classId: u.classId,
        studentIds: ids,
      );
}