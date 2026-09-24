import '../../core/models/scan_page.dart';
import '../../core/storage/local_store.dart';

class ScansRepository {
  ScansRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

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

  Future<void> save(ScanPage scan) async {
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
  }

  Future<void> delete(String id) async {
    final all = await _store.loadScans();
    await _store.saveScans(all.where((s) => s.id != id).toList());
  }
}