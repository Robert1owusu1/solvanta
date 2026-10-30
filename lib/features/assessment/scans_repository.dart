import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/models/scan_page.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';
import '../../core/storage/data_store.dart';

class ScansRepository {
  ScansRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  /// Photos captured while the upload could not go through, by scan id
  /// (base64), retried on the next [retryUploads]. The sync outbox only
  /// carries JSON, so the bytes wait here instead.
  static const _pendingKey = 'solvanta.scan_uploads_v1';

  Future<List<ScanPage>> all() => _store.loadScans();

  Future<List<ScanPage>> forAssessment(String assessmentId) async {
    final all = await _store.loadScans();
    return all.where((s) => s.assessmentId == assessmentId).toList();
  }

  Future<List<ScanPage>> forStudent(String studentId) async {
    final all = await _store.loadScans();
    return all.where((s) => s.studentId == studentId).toList();
  }

  Future<ScanPage?> forStudentAssessment(
      String studentId, String assessmentId) async {
    final all = await _store.loadScans();
    for (final s in all) {
      if (s.studentId == studentId && s.assessmentId == assessmentId) {
        return s;
      }
    }
    return null;
  }

  /// Saves [scan] and, with a backend, mirrors it there with its photo
  /// ([image]) so other staff devices can see the page.
  Future<void> save(ScanPage scan, {Uint8List? image}) async {
    final all = await _store.loadScans();
    final list = <ScanPage>[];
    var replaced = false;
    for (final s in all) {
      if (s.id == scan.id) {
        list.add(scan);
        replaced = true;
      } else {
        list.add(s);
      }
    }
    if (!replaced) list.add(scan);
    await _store.saveScans(list);

    final sync = ServerSync.instance;
    if (!sync.enabled) return;
    await sync.send('PUT', '/api/records/scans/${scan.id}', body: scan.toJson());
    if (image != null && image.isNotEmpty) {
      if (!await _upload(scan.id, image)) await _park(scan.id, image);
    }
  }

  Future<void> delete(String id) async {
    final all = await _store.loadScans();
    await _store.saveScans(all.where((s) => s.id != id).toList());
    await ServerSync.instance.send('DELETE', '/api/records/scans/$id');
  }

  /// The photo for [scan]: from the server when there is one, else null
  /// (this device previews its own captures from the picker).
  Future<Uint8List?> image(ScanPage scan) async {
    final pending = (await _pending())[scan.id];
    if (pending != null) return base64Decode(pending);
    if (!ServerSync.instance.enabled) return null;
    try {
      return await ApiClient().getBytes('/api/scans/${scan.id}/image');
    } catch (e) {
      debugPrint('[Scans] image ${scan.id}: $e');
      return null;
    }
  }

  /// Uploads photos parked while offline. Called after each server pull.
  Future<void> retryUploads() async {
    final pending = await _pending();
    if (pending.isEmpty) return;
    for (final e in pending.entries.toList()) {
      if (await _upload(e.key, base64Decode(e.value))) pending.remove(e.key);
    }
    await _savePending(pending);
  }

  Future<bool> _upload(String id, Uint8List image) async {
    try {
      await ApiClient().putBytes('/api/scans/$id/image', image, _mime(image));
      return true;
    } on ApiException catch (e) {
      // 404: the record has not reached the server yet; keep it for later.
      // Other refusals (too large, not your student) cannot succeed.
      return !(e.isNetwork || e.statusCode == 401 || e.statusCode == 404 ||
          e.statusCode >= 500);
    } catch (_) {
      return false;
    }
  }

  static String _mime(Uint8List b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
    if (b.length > 3 && b[0] == 0x52 && b[1] == 0x49) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _park(String id, Uint8List image) async {
    final pending = await _pending();
    pending[id] = base64Encode(image);
    await _savePending(pending);
  }

  Future<Map<String, String>> _pending() async {
    final raw = (await DataStore.instance()).getString(_pendingKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).cast<String, String>();
  }

  Future<void> _savePending(Map<String, String> pending) async {
    final prefs = await DataStore.instance();
    if (pending.isEmpty) {
      await prefs.remove(_pendingKey);
    } else {
      await prefs.setString(_pendingKey, jsonEncode(pending));
    }
  }
}
