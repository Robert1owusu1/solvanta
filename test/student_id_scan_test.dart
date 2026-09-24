import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:solvanta/features/attendance/student_check_in_screen.dart';
import 'package:solvanta/features/attendance/student_id_scanner_screen.dart';

/// Gate QR scanning: the payload parser (pure) and the scan → resolve →
/// confirm flow in the check-in screen (camera injected out in tests).
void main() {
  group('studentIdFromScan', () {
    test('decodes the student ID card payload', () {
      const raw =
          '{"v":1,"id":"STU-002","name":"Akosua Boaduwaa",'
          '"adm":"S-2023-002","sch":"Accra Junior High School","cls":"JHS2A"}';
      expect(studentIdFromScan(raw), 'STU-002');
    });

    test('tolerates a payload without the version field', () {
      expect(studentIdFromScan('{"id":"STU-008"}'), 'STU-008');
    });

    test('rejects malformed JSON, empty and oversized payloads', () {
      expect(studentIdFromScan('not json'), isNull);
      expect(studentIdFromScan(''), isNull);
      expect(studentIdFromScan(null), isNull);
      expect(studentIdFromScan('{"id":${'x' * 3000}}'), isNull);
    });

    test('rejects non-object JSON and non-string ids', () {
      expect(studentIdFromScan('[1,2,3]'), isNull);
      expect(studentIdFromScan('"just a string"'), isNull);
      expect(studentIdFromScan('{"id":123}'), isNull);
      expect(studentIdFromScan('{"v":1}'), isNull);
      expect(studentIdFromScan('{"id":"   "}'), isNull);
    });
  });

  group('check-in scan flow', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('a scanned id surfaces the student for manual confirmation',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: StudentCheckInScreen(
          openScanner: (_) async => 'STU-002', // camera injected out
        ),
      ));
      await tester.pumpAndSettle();

      // Scan button opens the (injected) scanner and resolves the student.
      await tester.tap(find.byIcon(Icons.qr_code_scanner));
      await tester.pumpAndSettle();

      // The scan must NOT check anyone in by itself — the staff member sees
      // the standard tile and has to press "Check in".
      expect(find.text('Akosua Boaduwaa'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Check in'), findsOneWidget);
      expect(find.textContaining('checked in today'), findsNothing);
    });

    testWidgets('scan → confirm records the arrival with the gate trail',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: StudentCheckInScreen(
          openScanner: (_) async => 'STU-002',
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.qr_code_scanner));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Check in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('checked in today'), findsOneWidget);

      // Let the outcome auto-clear timer fire so no timer outlives the tree.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an unknown scanned id warns instead of recording',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: StudentCheckInScreen(
          openScanner: (_) async => 'STU-999',
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.qr_code_scanner));
      await tester.pumpAndSettle();

      expect(find.textContaining('No student on this roll'), findsOneWidget);
      expect(find.textContaining('checked in today'), findsNothing);
    });
  });
}