/// The school's current academic term (doc §7, §19). Every dated record in
/// the app uses `yyyy-MM-dd` strings, so term scoping is a simple string
/// comparison against [start] / [end].
class SchoolTerm {
  final String year; // e.g. '2026/2027'
  final String name; // e.g. 'Term 1'
  final String start; // 'yyyy-MM-dd'
  final String end; // 'yyyy-MM-dd'

  /// When school reopens for the next term (`yyyy-MM-dd`), or `''` until the
  /// school announces it — printed as "Next term begins" on report cards.
  final String nextStart;

  const SchoolTerm({
    required this.year,
    required this.name,
    required this.start,
    required this.end,
    this.nextStart = '',
  });

  factory SchoolTerm.fromJson(Map<String, dynamic> json) => SchoolTerm(
        year: (json['year'] ?? '2026/2027') as String,
        name: (json['name'] ?? 'Term 1') as String,
        start: (json['start'] ?? '2026-09-07') as String,
        end: (json['end'] ?? '2026-12-18') as String,
        nextStart: (json['nextStart'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'year': year,
        'name': name,
        'start': start,
        'end': end,
        if (nextStart.isNotEmpty) 'nextStart': nextStart,
      };

  /// The label of the term after this one (`Term 2 · 2026/2027`; after
  /// Term 3, `Term 1 · 2027/2028`) — how fee structures name a term.
  String get nextLabel {
    final m = RegExp(r'\d').firstMatch(name);
    final n = m == null ? 1 : int.parse(m.group(0)!);
    if (n < 3) return '${name.replaceFirst(RegExp(r'\d'), '${n + 1}')} · $year';
    final years = RegExp(r'(\d{4})\D+(\d{4})').firstMatch(year);
    final nextYear = years == null
        ? year
        : '${int.parse(years.group(1)!) + 1}/${int.parse(years.group(2)!) + 1}';
    return '${name.replaceFirst(RegExp(r'\d'), '1')} · $nextYear';
  }

  String get label => '$name · $year';

  bool contains(String date) =>
      date.compareTo(start) >= 0 && date.compareTo(end) <= 0;

  static const SchoolTerm fallback = SchoolTerm(
    year: '2026/2027',
    name: 'Term 1',
    start: '2026-09-07',
    end: '2026-12-18',
  );
}