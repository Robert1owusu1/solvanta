import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/cover_assignment.dart';
import 'package:solvanta/features/timetable/cover_repository.dart';

CoverAssignment _c(String id, String date, {String sub = ''}) =>
    CoverAssignment(
      id: id,
      date: date,
      weekday: 'Monday',
      lessonId: 'LSN-$id',
      classId: 'JHS2A',
      subjectId: 'MATH',
      start: '08:00',
      end: '09:00',
      absentTeacherId: '',
      absentTeacherName: 'Ms. Efua',
      substituteTeacherId: sub,
      substituteTeacherName: sub.isEmpty ? '' : 'Mr. Kofi',
      status: sub.isEmpty ? 'open' : 'assigned',
    );

void main() {
  test('CoverAssignment JSON round-trips', () {
    final c = _c('1', '2026-09-21', sub: 'T-KOFI');
    final back = CoverAssignment.fromJson(c.toJson());
    expect(back.id, c.id);
    expect(back.substituteTeacherName, 'Mr. Kofi');
    expect(back.isAssigned, isTrue);
    expect(CoverAssignment.fromJson(_c('2', '2026-09-21').toJson()).isAssigned,
        isFalse);
  });

  test('repository upserts, filters by date, and removes', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = CoverRepository();

    await repo.upsert(_c('A', '2026-09-21'));
    await repo.upsert(_c('B', '2026-09-22'));
    expect((await repo.forDate('2026-09-21')).map((c) => c.id), ['A']);

    // Upserting the same id assigns a substitute rather than duplicating.
    await repo.upsert(_c('A', '2026-09-21', sub: 'T-KOFI'));
    final monday = await repo.forDate('2026-09-21');
    expect(monday.length, 1);
    expect(monday.single.isAssigned, isTrue);

    await repo.remove('A');
    expect(await repo.forDate('2026-09-21'), isEmpty);
    expect((await repo.forDate('2026-09-22')).map((c) => c.id), ['B']);
  });
}
