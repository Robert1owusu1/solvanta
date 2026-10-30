import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/class_room.dart';
import 'package:solvanta/core/models/grading.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/students/promotions_repository.dart';
import 'package:solvanta/features/students/year_end_screen.dart';

Student _s(String id, String classId) => Student(
      id: id,
      firstName: id,
      lastName: 'Test',
      gender: '',
      dateOfBirth: '',
      admissionDate: '',
      admissionNo: '',
      classId: classId,
      schoolId: 'SCH-001',
    );

const _classes = [
  ClassRoom(id: 'JHS2A', name: 'JHS2', stream: 'A'),
  ClassRoom(id: 'JHS3A', name: 'JHS3', stream: 'A'),
];

void main() {
  test('applies each decision once, and only real ones', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore();
    final up = _s('UP', 'JHS2A'), stay = _s('STAY', 'JHS2A');
    final done = _s('DONE', 'JHS3A'), open = _s('OPEN', 'JHS2A');
    await store.saveStudents([up, stay, done, open]);
    final repo = PromotionsRepository(store: store);
    final decisions = [
      YearEndDecision(
          student: up, classId: 'JHS2A', outcome: YearOutcome.promoted, average: 71),
      YearEndDecision(
          student: stay, classId: 'JHS2A', outcome: YearOutcome.repeated, average: 32),
      // JHS3 has no next class: promoting it means completing school.
      YearEndDecision(
          student: done, classId: 'JHS3A', outcome: YearOutcome.promoted, average: 64),
      YearEndDecision(
          student: open, classId: 'JHS2A', outcome: YearOutcome.review, average: 45),
    ];

    final n = await repo.apply(decisions,
        year: '2026/2027', classes: _classes, actor: 'Admin');
    expect(n, 3); // the review case waits for the headteacher

    final byId = {for (final s in await store.loadStudents()) s.id: s};
    expect(byId['UP']!.classId, 'JHS3A');
    expect(byId['STAY']!.classId, 'JHS2A');
    expect(byId['DONE']!.status, 'Graduated');
    expect(byId['OPEN']!.classId, 'JHS2A');

    final applied = await repo.appliedFor('2026/2027');
    expect(applied['UP']!.toClassId, 'JHS3A');
    expect(applied['DONE']!.outcome, YearOutcome.completed);
    expect(applied['UP']!.id, '2026-2027-UP');
    expect(applied.containsKey('OPEN'), isFalse);

    // Applying again — even with the student already moved — does nothing.
    final again = await repo.apply(
      [
        YearEndDecision(
            student: byId['UP']!,
            classId: 'JHS2A',
            outcome: YearOutcome.promoted,
            average: 71),
      ],
      year: '2026/2027',
      classes: _classes,
      actor: 'Admin',
    );
    expect(again, 0);
    expect((await store.loadStudents()).firstWhere((s) => s.id == 'UP').classId,
        'JHS3A');
    // A new year is a new decision.
    expect((await repo.appliedFor('2027/2028')), isEmpty);
  });

  testWidgets('outside Term 3 the screen only shows the year so far',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => AuthRepository()
        .login(email: 'admin@solvanta.app', password: 'admin123'));
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: const YearEndPromotionsScreen()));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('decided at the end of Term 3'), findsOneWidget);
    expect(find.text('Apply decisions'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in Term 3 the headteacher chooses where the rules are silent',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      await AuthRepository()
          .login(email: 'admin@solvanta.app', password: 'admin123');
      final store = LocalStore();
      await store.loadTerm(); // the seeded Term 1, with its marked work
      // Term 1 ends; Term 3 of the same year is now on.
      await store.saveTerm(const SchoolTerm(
          year: '2026/2027', name: 'Term 3', start: '2027-04-26', end: '2027-07-23'));
    });
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: const YearEndPromotionsScreen()));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('decided at the end of Term 3'), findsNothing);
    // The default scheme sets no promotion marks: every marked student waits
    // for a choice, and nothing can be applied until one is made.
    expect(find.text('Apply decisions'), findsNothing);
    final promote = find.text('Promote');
    expect(promote, findsWidgets);
    await tester.tap(promote.first);
    await tester.pump();
    expect(find.text('Apply decisions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
