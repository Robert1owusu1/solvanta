import '../../core/models/class_room.dart';
import '../../core/models/role.dart';
import '../../core/models/school.dart';
import '../../core/models/user.dart';
import '../../core/storage/local_store.dart';

class AdminRepository {
  AdminRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<School?> school() => _store.loadSchool();

  Future<void> saveSchool(School school) => _store.saveSchool(school);

  Future<List<ClassRoom>> classes() => _store.loadClasses();

  Future<void> saveClasses(List<ClassRoom> classes) =>
      _store.saveClasses(classes);

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

  String nextUserId(List<User> users) =>
      'USR-${users.length + 1}';

  Future<void> addOrUpdateUser(User user) async {
    final all = await _store.loadUsers();
    final list = <User>[];
    var added = false;
    for (final u in all) {
      if (u.id == user.id) {
        list.add(user);
        added = true;
      } else {
        list.add(u);
      }
    }
    if (!added) list.add(user);
    await _store.saveUsers(list);
  }

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