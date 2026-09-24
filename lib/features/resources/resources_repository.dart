import '../../core/models/school_assets.dart';
import '../../core/storage/phase6_store.dart';

class ResourcesRepository {
  final Phase6Store _store = Phase6Store();

  Future<List<ContentResource>> all() async {
    final raw = await _store.loadResourcesJson();
    return raw.map(ContentResource.fromJson).toList();
  }

  Future<List<ContentResource>> forClass(String classId) async {
    final raw = await _store.loadResourcesJson();
    return raw
        .map(ContentResource.fromJson)
        .where((r) => r.classId == classId)
        .toList();
  }

  Future<void> add({
    required ContentResource resource,
  }) async {
    final raw = await _store.loadResourcesJson();
    final list = raw.where((r) => r['id'] != resource.id).toList();
    list.add(resource.toJson());
    await _store.saveResourcesJson(list);
  }

  Future<void> delete(String id) async {
    final raw = await _store.loadResourcesJson();
    await _store.saveResourcesJson(
        raw.where((r) => r['id'] != id).toList());
  }
}