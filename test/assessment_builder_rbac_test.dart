import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/core/models/assessment.dart';
import 'package:solvanta/core/models/role.dart';
import 'package:solvanta/core/models/user.dart';
import 'package:solvanta/core/storage/local_store.dart';
import 'package:solvanta/features/assessment/assessment_builder_screen.dart';

/// Client-side gate for exam-type assessment creation.
///
/// Mirrors the backend's `adminOnlyAssessmentTypes` policy
/// (backend/internal/httpapi/assessments.go + rbac_test.go): teachers may
/// create classroom work (quiz / class test / exercise / homework / vacation)
/// but Mid-Term, End-of-Term, Mock, Diagnostic and Remedial assessments are
/// school-leaders only (superAdmin / schoolAdmin / headteacher).
Future<void> seedRole(AppRole role) async {
  final store = LocalStore();
  await store.saveUsers([
    User(
      id: 'USR-TEST',
      name: 'Role User',
      email: 'x@school.gh',
      phone: '',
      password: 'x',
      role: role,
    ),
  ]);
  await store.setSessionUser('USR-TEST');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('teacher type dropdown excludes exam types', (tester) async {
    await seedRole(AppRole.teacher);
    await tester.pumpWidget(
        const MaterialApp(home: AssessmentBuilderScreen()));
    await tester.pumpAndSettle();

    // Non-leaders get the policy hint under the Type field.
    expect(find.textContaining('created by your school admin'), findsOneWidget);

    // Open the type dropdown (default selection: Exercise).
    await tester.tap(find.text('Exercise'));
    await tester.pumpAndSettle();

    expect(find.text('Quiz'), findsOneWidget);
    expect(find.text('Class Test'), findsOneWidget);
    expect(find.text('Mid-Term Examination'), findsNothing);
    expect(find.text('End-of-Term Examination'), findsNothing);
    expect(find.text('Mock Examination'), findsNothing);
    expect(find.text('Diagnostic Assessment'), findsNothing);
    expect(find.text('Remedial Assessment'), findsNothing);
  });

  testWidgets('headteacher type dropdown includes exam types', (tester) async {
    await seedRole(AppRole.headteacher);
    await tester.pumpWidget(
        const MaterialApp(home: AssessmentBuilderScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('created by your school admin'), findsNothing);

    await tester.tap(find.text('Exercise'));
    await tester.pumpAndSettle();

    expect(find.text('Mid-Term Examination'), findsOneWidget);
    expect(find.text('End-of-Term Examination'), findsOneWidget);
    expect(find.text('Mock Examination'), findsOneWidget);
    expect(find.text('Diagnostic Assessment'), findsOneWidget);
    expect(find.text('Remedial Assessment'), findsOneWidget);
  });

  testWidgets('teacher opening a remedial-preset builder is refused',
      (tester) async {
    await seedRole(AppRole.teacher);
    final results = <bool?>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final ok = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => const AssessmentBuilderScreen(
                      presets: AssessmentBuilderPresets(
                        topicTitle: 'Reassessment — Fractions',
                        type: AssessmentType.remedial,
                      ),
                    ),
                  ),
                );
                results.add(ok);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The builder explains the policy and closes without creating anything.
    expect(
        find.textContaining('Only school admins and headteachers'),
        findsOneWidget);
    expect(find.text('New assessment'), findsNothing);
    expect(results, [false]);
  });
}