import '../../core/models/app_notification.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/notifications/notification_bridge.dart';
import '../../core/storage/local_store.dart';

class NotificationsRepository {
  NotificationsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<AppNotification>> all() => _store.loadNotifications();

  Future<void> push({
    required NotificationKind kind,
    required String title,
    required String body,
    String? userId,
    String? studentId,
  }) async {
    final all = await _store.loadNotifications();
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    final item = AppNotification(
      id: 'NOTIF-${DateTime.now().millisecondsSinceEpoch}',
      kind: kind,
      title: title,
      body: body,
      timestamp:
          '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}',
      userId: userId,
      studentId: studentId,
    );
    await _store.saveNotifications([item, ...all]);
    // Raise the OS notification too. The bridge no-ops when notifications
    // are disabled/unavailable and swallows platform errors, so this can
    // never break the in-app push (existing callers unchanged).
    await NotificationBridge.onPersisted(item);
  }

  Future<bool> canSee(
      AppNotification n, User user, List<Student> students) async {
    if (n.userId != null) return n.userId == user.id;
    if (user.role.isSchoolStaff) return true;
    if (n.studentId == null) return true;
    final student = students.where((s) => s.id == n.studentId).firstOrNull;
    if (student == null) return false;
    if (user.role.isParent) return user.studentIds.contains(n.studentId);
    if (user.role.isStudent) {
      // Their own records only — a pupil must never see another child's
      // notifications, regardless of that child having parents linked.
      return user.id == 'USR-${n.studentId}';
    }
    if (user.role.isTeacher) return student.classId == user.classId;
    return true;
  }

  Future<List<AppNotification>> visibleFor(
      User user, List<Student> students) async {
    final all = await _store.loadNotifications();
    final out = <AppNotification>[];
    for (final n in all) {
      if (await canSee(n, user, students)) out.add(n);
    }
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  Future<int> unreadCount(User user, List<Student> students) async {
    final visible = await visibleFor(user, students);
    return visible.where((n) => !n.read).length;
  }

  Future<void> markRead(String id) async {
    final all = await _store.loadNotifications();
    await _store.saveNotifications(all.map((n) {
      if (n.id == id) return n.copyWith(read: true);
      return n;
    }).toList());
  }

  Future<void> markAllRead(User user, List<Student> students) async {
    final all = await _store.loadNotifications();
    final ids = (await visibleFor(user, students))
        .where((n) => !n.read)
        .map((n) => n.id)
        .toSet();
    await _store.saveNotifications(all.map((n) {
      if (ids.contains(n.id)) return n.copyWith(read: true);
      return n;
    }).toList());
  }
}