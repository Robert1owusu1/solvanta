import 'class_room.dart';

/// The Ghanaian class ladder: Nursery → KG → Basic/Primary → JHS (or Basic
/// 7–9) → done. Class ids are a level plus a stream (`JHS2A`, `B4GOLD`).
class _Level {
  const _Level(this.prefix, this.number, this.stream);

  final String prefix;
  final int number;
  final String stream;

  String get name => '$prefix$number';
}

final _levelPattern = RegExp(r'^([A-Z]+?)\s*(\d+)\s*(.*)$');

_Level? _parse(String classId) {
  final m = _levelPattern.firstMatch(classId.toUpperCase().trim());
  if (m == null) return null;
  return _Level(m.group(1)!, int.parse(m.group(2)!), m.group(3)!);
}

/// The class a student in [classId] moves up to, or `null` when they are in
/// the final class (JHS3, Basic 9, SHS3) and complete school instead.
///
/// Promotion keeps the stream (JHS1A → JHS2A, not JHS1B). When [classes] is
/// given, the target is matched against the school's real classes: the same
/// stream if it exists, otherwise the first stream of the next level, and the
/// school's own naming decides the primary → JHS step (B6 → B7 if the school
/// has Basic 7, else JHS1).
String? nextClassId(String classId, [List<ClassRoom> classes = const []]) {
  final level = _parse(classId);
  if (level == null) return null;
  final names = {for (final c in classes) c.name.toUpperCase()};
  final hasBasicJhs = names.any((n) => RegExp(r'^B[789]$').hasMatch(n));

  String? nextName;
  switch (level.prefix) {
    case 'NURSERY' || 'CRECHE':
      nextName = level.number < 2 ? '${level.prefix}${level.number + 1}' : 'KG1';
    case 'KG':
      nextName = level.number < 2 ? 'KG${level.number + 1}' : null;
      nextName ??= names.any((n) => n.startsWith('P') && !n.startsWith('PRE'))
          ? 'P1'
          : 'B1';
    case 'B' || 'BS' || 'BASIC' || 'P' || 'PRIMARY':
      final top = level.prefix.startsWith('B') && hasBasicJhs ? 9 : 6;
      if (level.number < top) {
        nextName = '${level.prefix}${level.number + 1}';
      } else if (top == 6) {
        nextName = 'JHS1';
      }
    case 'JHS' || 'SHS':
      nextName = level.number < 3 ? '${level.prefix}${level.number + 1}' : null;
    default:
      return null;
  }
  if (nextName == null) return null;

  final sameStream = '$nextName${level.stream}';
  if (classes.isEmpty) return sameStream;
  final ids = classes.map((c) => c.id.toUpperCase()).toSet();
  if (ids.contains(sameStream)) return sameStream;
  final atLevel = classes
      .where((c) => c.name.toUpperCase() == nextName)
      .map((c) => c.id)
      .toList()
    ..sort();
  return atLevel.isEmpty ? sameStream : atLevel.first;
}

/// The level of [classId] without its stream (`JHS2A` → `JHS2`), or the id
/// itself when it doesn't look like a level.
String classLevel(String classId) => _parse(classId)?.name ?? classId;
