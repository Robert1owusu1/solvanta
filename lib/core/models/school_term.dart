/// The school's current academic term (doc §7, §19). Every dated record in
/// the app uses `yyyy-MM-dd` strings, so term scoping is a simple string
/// comparison against [start] / [end].
class SchoolTerm {
  final String year; // e.g. '2026/2027'
  final String name; // e.g. 'Term 1'
  final String start; // 'yyyy-MM-dd'
  final String end; // 'yyyy-MM-dd'

  const SchoolTerm({
    required this.year,
    required this.name,
    required this.start,
    required this.end,
  });

  factory SchoolTerm.fromJson(Map<String, dynamic> json) => SchoolTerm(
        year: (json['year'] ?? '2026/2027') as String,
        name: (json['name'] ?? 'Term 1') as String,
        start: (json['start'] ?? '2026-09-07') as String,
        end: (json['end'] ?? '2026-12-18') as String,
      );

  Map<String, dynamic> toJson() =>
      {'year': year, 'name': name, 'start': start, 'end': end};

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