import '../../core/models/audit.dart';
import '../../core/storage/local_store.dart';

class AuditRepository {
  AuditRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<AuditEntry>> all() async {
    final list = await _store.loadAudit();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  Future<void> log({
    required String action,
    required String actor,
    required String target,
    required String detail,
    String? reason,
  }) async {
    final all = await _store.loadAudit();
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    final entry = AuditEntry(
      id: 'AUDIT-${DateTime.now().millisecondsSinceEpoch}',
      action: action,
      actor: actor,
      target: target,
      detail: detail,
      timestamp:
          '${n.year}-${p(n.month)}-${p(n.day)} ${p(n.hour)}:${p(n.minute)}',
      reason: reason,
    );
    await _store.saveAudit([entry, ...all]);
  }
}