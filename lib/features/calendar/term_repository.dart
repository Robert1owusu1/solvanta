import '../../core/models/school_term.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

/// Reads/writes the current academic term (doc §7, §19).
class TermRepository {
  final LocalStore _store;

  TermRepository({LocalStore? store}) : _store = store ?? LocalStore();

  Future<SchoolTerm> current() => _store.loadTerm();

  Future<void> setTerm(SchoolTerm term) async {
    await _store.saveTerm(term);
    await ServerSync.instance.send('PUT', '/api/school/term', body: term.toJson());
  }
}