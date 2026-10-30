import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/admin/schools_screen.dart';

void main() {
  testWidgets('lists schools and onboards one with its admin', (tester) async {
    final schools = <Map<String, dynamic>>[
      {'id': 'SCH-001', 'name': 'Accra Junior High School', 'region': 'Greater Accra'},
    ];
    final calls = <String>[];
    final api = ApiClient(
      baseUrl: 'http://api.test',
      client: MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.method == 'GET' && req.url.path == '/api/schools') {
          return http.Response(jsonEncode(schools), 200);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (req.url.path == '/api/schools') {
          schools.add(body);
          return http.Response(jsonEncode(body), 201);
        }
        expect(body['schoolId'], 'SCH-002');
        expect(body['role'], 'schoolAdmin');
        return http.Response(jsonEncode({...body, 'id': 'USR-1'}), 201);
      }),
    );
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: SchoolsScreen(client: api)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Accra Junior High School'), findsOneWidget);

    await tester.tap(find.text('Add school'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'sch-002');
    await tester.enterText(fields.at(1), 'Kumasi Basic School');
    await tester.enterText(fields.at(3), 'Abena Mensah');
    await tester.enterText(fields.at(4), 'abena@kumasi.edu.gh');
    await tester.enterText(fields.at(5), 'Temporary1Pass');
    await tester.tap(find.text('Create school'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    // The list reloads from the server.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, containsAllInOrder(['POST /api/schools', 'POST /api/users']));
    expect(find.textContaining('Kumasi Basic School is ready'), findsOneWidget);
    // The list refreshes in place (this used to throw: setState returned a
    // Future, so the screen never rebuilt).
    expect(find.text('Kumasi Basic School'), findsOneWidget);

    // Opened again, the new school is listed from the server.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: SchoolsScreen(client: api)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Kumasi Basic School'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('suspends a school; delete only once suspended', (tester) async {
    final schools = <Map<String, dynamic>>[
      {'id': 'SCH-001', 'name': 'Platform School'},
      {'id': 'SCH-002', 'name': 'Kumasi Basic School', 'suspended': false},
    ];
    final calls = <String>[];
    final api = ApiClient(
      baseUrl: 'http://api.test',
      client: MockClient((req) async {
        calls.add('${req.method} ${req.url.path}');
        if (req.url.path.endsWith('/suspend')) schools[1]['suspended'] = true;
        if (req.method == 'GET') return http.Response(jsonEncode(schools), 200);
        return http.Response('{}', 200);
      }),
    );
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(), home: SchoolsScreen(client: api)));
    await settle();

    // The platform's own school can't be suspended.
    await tester.tap(find.text('Platform School'));
    await tester.pumpAndSettle();
    expect(find.text('Suspend access'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kumasi Basic School'));
    await tester.pumpAndSettle();
    expect(find.text('Delete school'), findsNothing); // not before suspending
    await tester.tap(find.text('Suspend access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suspend'));
    await settle();
    expect(calls, contains('POST /api/schools/SCH-002/suspend'));
    expect(find.textContaining('Suspended'), findsOneWidget);

    await tester.tap(find.text('Kumasi Basic School'));
    await tester.pumpAndSettle();
    expect(find.text('Delete school'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
