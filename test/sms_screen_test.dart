import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solvanta/core/api/api_client.dart';
import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/features/admin/sms_screen.dart';

void main() {
  testWidgets('shows the provider, turns events on and lists texts',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var settings = <String, dynamic>{'enabled': false};
    final puts = <Map<String, dynamic>>[];
    final api = ApiClient(
      baseUrl: 'http://api.test',
      client: MockClient((req) async {
        if (req.url.path == '/api/sms/settings' && req.method == 'PUT') {
          settings = jsonDecode(req.body) as Map<String, dynamic>;
          puts.add(settings);
        }
        if (req.url.path == '/api/sms/log') {
          return http.Response(
              jsonEncode([
                {
                  'to': '233244000004',
                  'text': 'Kojo Owusu was marked absent on 2026-10-12.',
                  'status': 'logged',
                  'at': '2026-10-12 08:10',
                },
              ]),
              200);
        }
        return http.Response(
            jsonEncode({
              'settings': settings,
              'provider': 'log',
              'usage': {'month': '2026-10', 'sent': 12, 'failed': 1, 'logged': 0},
            }),
            200);
      }),
    );
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: SmsScreen(client: api)));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('No SMS provider connected'), findsOneWidget);
    expect(find.text("Sender name: the platform's"), findsOneWidget);
    expect(find.textContaining('12 sent · 1 failed'), findsOneWidget);
    expect(find.text('Kojo Owusu was marked absent on 2026-10-12.'),
        findsOneWidget);
    // Events stay disabled until the master switch is on.
    expect(
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Absence')).onChanged,
        isNull);
    await tester.tap(find.text('Text parents'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(puts.single['enabled'], isTrue);
    expect(tester.takeException(), isNull);
  });
}
