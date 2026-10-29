import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:solvanta/core/theme/app_theme.dart';
import 'package:solvanta/core/ui/data_table.dart';

/// The desktop table: sort by a column (and back), page through, open a row.
void main() {
  final people = [
    for (var i = 1; i <= 23; i++) (name: 'Pupil ${i.toString().padLeft(2, '0')}', score: (i * 37) % 100),
  ];

  Future<void> pump(WidgetTester tester, {void Function(String)? onOpen}) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SvDataTable<({String name, int score})>(
          rows: people,
          initialSort: 0,
          pageSize: 10,
          onOpen: (p) => onOpen?.call(p.name),
          actions: (p) => IconButton(tooltip: 'Menu ${p.name}', onPressed: () {}, icon: const Icon(Icons.more_vert)),
          columns: [
            SvColumn(label: 'Name', sortKey: (p) => p.name, cell: (p) => Text(p.name)),
            SvColumn(label: 'Score', numeric: true, sortKey: (p) => p.score, cell: (p) => Text('${p.score}')),
            SvColumn(label: 'Note', cell: (_) => const Text('–')),
          ],
        ),
      ),
    ));
  }

  List<String> namesShown(WidgetTester tester) => tester
      .widgetList<Text>(find.textContaining('Pupil '))
      .map((t) => t.data!)
      .toList();

  testWidgets('sorts, pages and opens rows', (tester) async {
    String? opened;
    await pump(tester, onOpen: (n) => opened = n);

    expect(namesShown(tester).first, 'Pupil 01');
    expect(namesShown(tester), hasLength(10));
    expect(find.text('Showing 1–10 of 23'), findsOneWidget);

    // Name again: descending.
    await tester.tap(find.text('NAME'));
    await tester.pump();
    expect(namesShown(tester).first, 'Pupil 23');

    // Score: ascending, numbers compared as numbers.
    await tester.tap(find.text('SCORE'));
    await tester.pump();
    final scores = tester
        .widgetList<Text>(find.byWidgetPredicate((w) => w is Text && RegExp(r'^\d+$').hasMatch(w.data ?? '')))
        .map((t) => int.parse(t.data!))
        .toList();
    expect(scores, orderedEquals([...scores]..sort()));

    // A column without a sort key does nothing.
    await tester.tap(find.text('NOTE'));
    await tester.pump();

    // Last page holds the remainder.
    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    await tester.tap(find.byTooltip('Next page'));
    await tester.pump();
    expect(find.text('Showing 21–23 of 23'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right)).onPressed, isNull);

    await tester.tap(find.textContaining('Pupil ').first);
    expect(opened, isNotNull);
    expect(find.byIcon(Icons.more_vert), findsNWidgets(3));
  });
}
