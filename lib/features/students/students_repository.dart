import '../../core/models/class_room.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/storage/local_store.dart';

class StudentsRepository {
  StudentsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<ClassRoom>> classes() => _store.loadClasses();

  Future<List<Student>> all() => _store.loadStudents();

  Future<List<Student>> active() async {
    final all = await _store.loadStudents();
    return all.where((s) => s.status == 'Active').toList();
  }

  /// Students visible to [user], mirroring the backend `listStudents` scope:
  /// staff see everyone, teachers only their own class, parents their
  /// children, students themselves. Always the primary student-list method
  /// for screens so offline mode matches the API's role scoping.
  Future<List<Student>> visibleToUser(User? user) async {
    final all = await active();
    final role = user?.role;
    if (role == null) return all;
    if (role.canViewAllStudents) return all;
    if (role.isTeacher) {
      return all.where((s) => s.classId == user!.classId).toList();
    }
    if (role.isParent) {
      return all.where((s) => user!.studentIds.contains(s.id)).toList();
    }
    if (role.isStudent) {
      return all.where((s) => 'USR-${s.id}' == user!.id).toList();
    }
    return all;
  }

  Future<List<Student>> byClass(String classId) async {
    final all = await active();
    return all.where((s) => s.classId == classId).toList();
  }

  Future<Student?> byId(String id) async {
    final students = await _store.loadStudents();
    for (final s in students) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<List<Student>> byParentAll(User parent) async {
    final all = await active();
    return all.where((s) => parent.studentIds.contains(s.id)).toList();
  }

  Future<List<Student>> byParentUserAll(String parentUserId) async {
    final all = await active();
    return all.where((s) => s.parentUserId == parentUserId).toList();
  }

  Future<Student?> byParentUser(String parentUserId) async {
    final all = await active();
    for (final s in all) {
      if (s.parentUserId == parentUserId) return s;
    }
    return null;
  }

  Future<Student?> studentForUser(User user) async {
    final all = await _store.loadStudents();
    if (user.studentIds.isNotEmpty) {
      for (final id in user.studentIds) {
        final match = all.where((s) => s.id == id).firstOrNull;
        if (match != null) return match;
      }
    }
    return all.where((s) => 'USR-${s.id}' == user.id).firstOrNull;
  }

  Future<void> saveStudent(Student student) async {
    final all = await _store.loadStudents();
    final list = <Student>[];
    var added = false;
    for (final s in all) {
      if (s.id == student.id) {
        list.add(student);
        added = true;
      } else {
        list.add(s);
      }
    }
    if (!added) list.add(student);
    await _store.saveStudents(list);
  }

  Future<void> deleteStudent(String id) async {
    final all = await _store.loadStudents();
    await _store.saveStudents(all.where((s) => s.id != id).toList());
  }

  Future<String> nextStudentId(List<Student> existing) async {
    var max = 0;
    for (final s in existing) {
      final n = int.tryParse(s.id.replaceAll(RegExp(r'[^0-9]'), ''));
      if (n != null && n > max) max = n;
    }
    return 'STU-${(max + 1).toString().padLeft(3, '0')}';
  }
}