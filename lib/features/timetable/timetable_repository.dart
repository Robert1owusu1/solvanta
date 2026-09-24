import '../../core/models/timetable.dart';
import '../../core/storage/phase6_store.dart';

class TimetableRepository {
  final Phase6Store _store = Phase6Store();

  Future<List<LessonSlot>> loadSlots() async {
    final list = await _store.loadLessonsJson();
    return list.map(LessonSlot.fromJson).toList();
  }

  Future<void> saveSlots(List<LessonSlot> slots) async {
    await _store.saveLessonsJson(slots.map((e) => e.toJson()).toList());
  }
}
