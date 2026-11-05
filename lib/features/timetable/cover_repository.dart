import 'dart:convert';

import '../../core/models/cover_assignment.dart';
import '../../core/storage/phase6_store.dart';
import '../../core/sync/server_sync.dart';

/// Reads and writes cover/substitution assignments, mirroring each change to
/// the backend's `cover_assignments` record kind — the same offline-first
/// pattern the timetable uses.
class CoverRepository {
  final Phase6Store _store = Phase6Store();

  Future<List<CoverAssignment>> load() async {
    final list = await _store.loadCoverJson();
    return list.map(CoverAssignment.fromJson).toList();
  }

  Future<List<CoverAssignment>> forDate(String date) async {
    final all = await load();
    return [for (final c in all) if (c.date == date) c]
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Replaces the stored set, pushing each added/edited row and deleting any
  /// removed one, exactly like [TimetableRepository.saveSlots].
  Future<void> save(List<CoverAssignment> assignments) async {
    final before = {
      for (final c in await _store.loadCoverJson()) c['id'] as String: c,
    };
    final after = [for (final c in assignments) c.toJson()];
    await _store.saveCoverJson(after);

    final sync = ServerSync.instance;
    if (!sync.enabled) return;
    for (final c in after) {
      final id = c['id'] as String;
      if (jsonEncode(before.remove(id)) != jsonEncode(c)) {
        await sync.send('PUT', '/api/records/cover_assignments/$id', body: c);
      }
    }
    for (final id in before.keys) {
      await sync.send('DELETE', '/api/records/cover_assignments/$id');
    }
  }

  /// Upserts one assignment by id.
  Future<void> upsert(CoverAssignment c) async {
    final all = await load();
    final i = all.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      all[i] = c;
    } else {
      all.add(c);
    }
    await save(all);
  }

  Future<void> remove(String id) async {
    final all = await load();
    await save([for (final c in all) if (c.id != id) c]);
  }
}
