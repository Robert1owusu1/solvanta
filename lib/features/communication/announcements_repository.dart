import '../../core/models/announcement.dart';
import '../../core/models/app_notification.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../notifications/notifications_repository.dart';
import '../students/students_repository.dart';

/// Persists school/class/emergency announcements (doc §40) and fans each new
/// announcement out into the Notifications inbox.
class AnnouncementsRepository {
  final LocalStore _store;

  AnnouncementsRepository({LocalStore? store}) : _store = store ?? LocalStore();

  Future<List<Announcement>> active() async {
    final items = await _store.loadAnnouncements();
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  /// Announcements this user can see: school + emergency broadcast to
  /// everyone; class announcements follow the class-role rules.
  Future<List<Announcement>> visibleFor(
      User user, List<Student> students) async {
    final items = await _store.loadAnnouncements();

    bool ok(Announcement a) {
      if (a.audience != AnnouncementAudience.classes) return true;
      if (a.targetClassId == null) return true;
      if (user.isSchoolStaff) return true;
      if (user.role.isStudent) {
        return a.targetClassId ==
            students
                .where((s) => s.id == user.id.replaceFirst('USR-', ''))
                .toList()
                .firstOrNull
                ?.classId;
      }
      if (user.role.isParent) {
        return students.any((s) =>
            user.studentIds.contains(s.id) &&
            s.classId == a.targetClassId);
      }
      return user.classId == a.targetClassId;
    }

    return items.where(ok).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  Future<void> create({
    required String title,
    required String body,
    required AnnouncementAudience audience,
    String? targetClassId,
    required String authorId,
    required String authorName,
  }) async {
    final item = Announcement(
      id: 'ANNC-${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim(),
      body: body.trim(),
      audience: audience,
      targetClassId:
          audience == AnnouncementAudience.classes ? targetClassId : null,
      authorId: authorId,
      authorName: authorName,
      timestamp: _stamp(),
    );
    final items = await _store.loadAnnouncements();
    await _store.saveAnnouncements([item, ...items]);

    // With a backend, the server stores it (with its own id) and fans out
    // the notifications itself; keep its copy so every device agrees.
    if (ServerSync.instance.enabled) {
      final res = await ServerSync.instance
          .send('POST', '/api/announcements', body: item.toJson());
      if (res is Map<String, dynamic>) {
        final saved = Announcement.fromJson(res);
        final now = await _store.loadAnnouncements();
        await _store.saveAnnouncements(
            [for (final a in now) a.id == item.id ? saved : a]);
      }
      return;
    }

    // Thread the announcement into the Notifications inbox.
    final notif = NotificationsRepository(store: _store);
    final prefix = audience == AnnouncementAudience.emergency
        ? '⚠️ '
        : audience == AnnouncementAudience.classes
            ? 'Class: '
            : '';
    if (audience == AnnouncementAudience.classes) {
      final all = await StudentsRepository().all();
      for (final s in all.where((s) => s.classId == targetClassId)) {
        await notif.push(
          kind: NotificationKind.announcement,
          title: '$prefix${item.title}',
          body: item.body,
          studentId: s.id,
        );
      }
    } else {
      await notif.push(
        kind: NotificationKind.announcement,
        title: '$prefix${item.title}',
        body: item.body,
      );
    }
  }

  Future<void> delete(String id) async {
    final items = await _store.loadAnnouncements();
    await _store.saveAnnouncements(items.where((a) => a.id != id).toList());
    await ServerSync.instance.send('DELETE', '/api/announcements/$id');
  }

  String _stamp() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}