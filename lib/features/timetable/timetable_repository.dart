import 'dart:convert';

import '../../core/models/timetable.dart';
import '../../core/storage/phase6_store.dart';
import '../../core/sync/server_sync.dart';

class TimetableRepository {
  final Phase6Store _store = Phase6Store();

  Future<List<LessonSlot>> loadSlots() async {
    final list = await _store.loadLessonsJson();
    return list.map(LessonSlot.fromJson).toList();
  }

  /// Replaces the timetable, mirroring each added, edited or removed slot to
  /// the backend.
  Future<void> saveSlots(List<LessonSlot> slots) async {
    final before = {
      for (final s in await _store.loadLessonsJson()) s['id'] as String: s,
    };
    final after = [for (final s in slots) s.toJson()];
    await _store.saveLessonsJson(after);

    final sync = ServerSync.instance;
    if (!sync.enabled) return;
    for (final s in after) {
      final id = s['id'] as String;
      if (jsonEncode(before.remove(id)) != jsonEncode(s)) {
        await sync.send('PUT', '/api/records/lessons/$id', body: s);
      }
    }
    for (final id in before.keys) {
      await sync.send('DELETE', '/api/records/lessons/$id');
    }
  }
}
