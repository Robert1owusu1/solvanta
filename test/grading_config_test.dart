import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/class_room.dart';
import 'package:solvanta/core/models/grading.dart';
import 'package:solvanta/core/models/question.dart';
import 'package:solvanta/core/models/school.dart';
import 'package:solvanta/core/models/school_term.dart';
import 'package:solvanta/core/models/student.dart';
import 'package:solvanta/core/models/submission.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/admin/grading_settings_screen.dart';
import 'package:solvanta/features/auth/auth_repository.dart';
import 'package:solvanta/features/reports/report_card_pdf.dart';

/// A school that grades JHS 40/60 on the 1–9 scale, its primary classes
/// (B1–B6) 50/50 with letters, and anything else on the GES default.
final _school = GradingConfig(schemes: [
  gesBasicPreset.copyWith(name: 'Everything else', isDefault: true),
  GradingScheme.fromJson({
    ...gesBasicPreset.toJson(),
    'id': 'jhs',
    'name': 'JHS',
    'classNames': ['JHS1', 'JHS2', 'JHS3'],
    'classWeight': 40,
    'examWeight': 60,
  }),
  GradingScheme.fromJson({
    ...letterPreset.toJson(),
    'id': 'primary',
    'name': 'Primary',
    'classNames': ['B1', 'B2', 'B3', 'B4', 'B5', 'B6'],
  }),
]);

const _classes = [
  ClassRoom(id: 'JHS2A', name: 'JHS2', stream: 'A'),
  ClassRoom(id: 'B4GOLD', name: 'B4', stream: 'GOLD'),
  ClassRoom(id: 'KG1A', name: 'KG1', stream: 'A'),
];

Student _student(String id, String classId) => Student(
      id: id,
      firstName: 'Ama',
      lastName: 'Mensah',
      gender: 'Female',
      dateOfBirth: '2014-01-01',
      admissionDate: '2020-09-01',
      admissionNo: 'ADM-$id',
      classId: classId,
      schoolId: 'SCH-001',
    );

Assessment _paper(String subject, String classId, AssessmentType type) =>
    Assessment(
      id: '$classId-$subject-${type.name}',
      title: '$subject ${type.label}',
      type: type,
      subjectId: subject,
      classId: classId,
      date: '2026-10-01',
      createdBy: 'T',
      questions: [
        Question(
          id: 'Q-$subject',
          type: QuestionType.structured,
          subjectId: subject,
          classId: classId,
          topic: 't',
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 100,
          stem: 's',
        ),
      ],
    );

AssessmentSubmission _mark(Assessment a, Student s, double earned) =>
    AssessmentSubmission(
      id: '${a.id}-${s.id}',
      assessmentId: a.id,
      studentId: s.id,
      classId: s.classId,
      date: a.date,
      answers: const {},
      teacherMarks: const {},
      earned: earned,
    );

/// Class work 80, exam 70 in Maths and English for [s].
ReportCardData _card(Student s) {
  final papers = [
    for (final subj in ['MATH', 'ENG'])
      for (final t in [AssessmentType.classTest, AssessmentType.endTerm])
        _paper(subj, s.classId, t),
  ];
  return ReportCardDataBuilder.build(
    student: s,
    school: const School(id: 'SCH-001', name: 'Test School'),
    term: SchoolTerm.fallback,
    assessments: papers,
    subs: [
      for (final p in papers)
        _mark(p, s, p.type == AssessmentType.endTerm ? 70 : 80),
    ],
    roster: [s],
    grading: _school,
    classes: _classes,
  );
}

void main() {
  // Report-card PDFs load their bundled font through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scheme for a class', () {
    test('by the class list level, then by prefix, then the default', () {
      expect(_school.schemeFor('JHS2A', _classes).name, 'JHS');
      expect(_school.schemeFor('B4GOLD', _classes).name, 'Primary');
      // Not in the class list: JHS3B still starts with JHS3.
      expect(_school.schemeFor('JHS3B', _classes).name, 'JHS');
      expect(_school.schemeFor('KG1A', _classes).name, 'Everything else');
    });

    test('B1 does not swallow B10 when both are named', () {
      final g = GradingConfig(schemes: [
        letterPreset.copyWith(name: 'Lower', isDefault: true),
        GradingScheme.fromJson({
          ...letterPreset.toJson(),
          'id': 'upper',
          'name': 'Upper',
          'classNames': ['B10'],
        }),
      ]);
      expect(g.schemeFor('B10A').name, 'Upper');
    });
  });

  test('banner level from Ghanaian class names', () {
    expect(schoolLevelFor('B4GOLD'), 'PRIMARY SCHOOL');
    expect(schoolLevelFor('B8A'), 'JUNIOR HIGH SCHOOL');
    expect(schoolLevelFor('BASIC 2'), 'PRIMARY SCHOOL');
    expect(schoolLevelFor('P3A'), 'PRIMARY SCHOOL');
    expect(schoolLevelFor('KG1A'), 'KINDERGARTEN');
    expect(schoolLevelFor('NURSERY1'), 'PRE-SCHOOL');
    expect(schoolLevelFor('JHS2A'), 'JUNIOR HIGH SCHOOL');
    expect(schoolLevelFor('PEARL'), '');
  });

  group('validation (mirrors the server)', () {
    GradingScheme jhs([Map<String, dynamic> change = const {}]) =>
        GradingScheme.fromJson({..._school.schemes[1].toJson(), ...change});
    GradingConfig withJhs(GradingScheme s) =>
        GradingConfig(schemes: [_school.schemes[0], s]);

    test('the sample school is valid', () {
      expect(_school.problem(), isNull);
    });
    test('split must add up to 100', () {
      expect(jhs({'examWeight': 50}).problem(), contains('add up to 100'));
    });
    test('a class can follow only one scheme', () {
      final clash = GradingConfig(schemes: [
        ..._school.schemes,
        jhs({'id': 'jhs-2', 'name': 'JHS again', 'classNames': ['JHS1']}),
      ]);
      expect(clash.problem(), contains('JHS1 is in both'));
    });
    test('exactly one default', () {
      expect(GradingConfig(schemes: [jhs()]).problem(), contains('default'));
    });
    test('lowest band starts at 0 and bands are distinct', () {
      expect(
        jhs({
          'bands': [
            {'min': 50, 'grade': '1', 'remark': ''},
            {'min': 20, 'grade': '2', 'remark': ''},
          ],
        }).problem(),
        contains('start at 0'),
      );
      expect(
        jhs({
          'bands': [
            {'min': 0, 'grade': '1', 'remark': ''},
            {'min': 0, 'grade': '2', 'remark': ''},
          ],
        }).problem(),
        contains('two bands'),
      );
    });
    test('an aggregate needs whole-number grades', () {
      final letters = GradingScheme.fromJson(
          {...letterPreset.toJson(), 'classNames': ['B1'], 'showAggregate': true});
      expect(letters.problem(), contains('whole-number'));
    });
    test('a scheme that is not the default needs classes', () {
      expect(withJhs(jhs({'classNames': []})).problem(),
          contains('choose the classes'));
    });
    test('survives a JSON round trip', () {
      final back = GradingConfig.fromJson(_school.toJson());
      expect(back.toJson(), _school.toJson());
    });
  });

  group('report cards follow the class scheme', () {
    test('JHS: 40/60 on the 1–9 scale', () {
      final card = _card(_student('S1', 'JHS2A'));
      final maths = card.subjects.firstWhere((s) => s.subjectId == 'MATH');
      expect(maths.classScore, closeTo(32, 1e-9)); // 80 × 40%
      expect(maths.examScore, closeTo(42, 1e-9)); // 70 × 60%
      expect(maths.total, closeTo(74, 1e-9));
      expect(maths.termGrade, '2');
      expect(card.scheme.name, 'JHS');
    });

    test('primary: 50/50 with letter grades and no aggregate', () {
      final card = _card(_student('S2', 'B4GOLD'));
      final maths = card.subjects.firstWhere((s) => s.subjectId == 'MATH');
      expect(maths.total, closeTo(75, 1e-9)); // 40 + 35
      expect(maths.termGrade, 'B');
      expect(maths.termRemark, 'Very Good');
      expect(card.aggregate, isNull);
      expect(card.scheme.showAggregate, isFalse);
    });

    test('an unlisted class falls back to the default scheme', () {
      final card = _card(_student('S3', 'KG1A'));
      final maths = card.subjects.firstWhere((s) => s.subjectId == 'MATH');
      expect(maths.total, closeTo(73, 1e-9)); // 30/70
    });

    test('PDFs render with each scheme', () async {
      final out = Platform.environment['REPORT_CARD_OUT'];
      for (final s in [_student('S1', 'JHS2A'), _student('S2', 'B4GOLD')]) {
        for (final t in ReportCardTemplate.values) {
          final bytes = await buildReportCardPdf(_card(s), t);
          expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
          if (out != null) {
            File('$out/grading_${s.classId}_${t.name}.pdf')
                .writeAsBytesSync(bytes);
          }
        }
      }
    });
  });

  test('charts and exports grade with the class scheme', () async {
    SharedPreferences.setMockInitialValues({});
    await LocalStore().saveGradingConfig(_school);
    expect(schoolGrade(74, 'JHS2A'), '2');
    expect(schoolGrade(75, 'B4GOLD'), 'B');
    expect(schoolGrade(75, 'KG1A'), '2'); // default scheme
    // A config that breaks the rules is never made current.
    await LocalStore().saveGradingConfig(GradingConfig(schemes: const []));
    expect(schoolGrade(75, 'B4GOLD'), 'B');
    await LocalStore().saveGradingConfig(GradingConfig.fallback);
  });

  test('a saved config is read back; a corrupt one falls back', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore();
    expect((await store.loadGradingConfig()).defaultScheme.classWeight, 30);
    await store.saveGradingConfig(_school);
    expect((await store.loadGradingConfig()).schemes.length, 3);
    SharedPreferences.setMockInitialValues({'solvanta.grading_v1': '{"schemes":[]}'});
    expect((await LocalStore().loadGradingConfig()).schemes.single.name,
        'GES basic school');
  });

  group('grading screen', () {
    Future<void> open(WidgetTester tester, String email, String pw) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(
          () => AuthRepository().login(email: email, password: pw));
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(), home: const GradingSettingsScreen()));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('the school admin can add a scheme', (tester) async {
      await open(tester, 'admin@solvanta.app', 'admin123');
      expect(find.text('GES basic school'), findsOneWidget);
      expect(find.textContaining('Only the school admin'), findsNothing);
      expect(find.text('Add scheme for other classes'), findsOneWidget);
    });

    testWidgets('the scheme editor opens and lays out on a phone',
        (tester) async {
      await open(tester, 'admin@solvanta.app', 'admin123');
      await tester.tap(find.text('GES basic school'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Edit scheme'), findsOneWidget);
      expect(find.text('Class score 30%  ·  Exam 70%'), findsOneWidget);
      await tester.tap(find.text('40/60'));
      await tester.pump();
      expect(find.text('Class score 40%  ·  Exam 60%'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the headteacher only sees it', (tester) async {
      await open(tester, 'head@school.gh', 'head123');
      expect(find.text('GES basic school'), findsOneWidget);
      expect(find.textContaining('Only the school admin'), findsOneWidget);
      expect(find.text('Add scheme for other classes'), findsNothing);
    });
  });
}
