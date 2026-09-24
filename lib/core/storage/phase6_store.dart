import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class Phase6Store {
  static const _lessonsKey = 'solvanta.lessons_v1';
  static const _resourcesKey = 'solvanta.resources_v1';
  static const _safetyPacksKey = 'solvanta.safety_packs_v1';
  static const _safetyCompletionsKey = 'solvanta.safety_completions_v1';

  Future<List<Map<String, dynamic>>> loadLessonsJson() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lessonsKey);
    if (raw == null) {
      final list = _seedLessonsJson();
      await saveLessonsJson(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> saveLessonsJson(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lessonsKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> loadResourcesJson() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_resourcesKey);
    if (raw == null) {
      final list = _seedResourcesJson();
      await saveResourcesJson(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> saveResourcesJson(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_resourcesKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> loadSafetyPacksJson() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_safetyPacksKey);
    if (raw == null) {
      final list = _seedSafetyPacksJson();
      await saveSafetyPacksJson(list);
      return list;
    }
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> saveSafetyPacksJson(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_safetyPacksKey, jsonEncode(list));
  }

  Future<List<Map<String, dynamic>>> loadSafetyCompletionsJson() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_safetyCompletionsKey);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> saveSafetyCompletionsJson(
      List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_safetyCompletionsKey, jsonEncode(list));
  }

  List<Map<String, dynamic>> _seedLessonsJson() {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'];
    const subjects = ['MATH', 'ENG', 'SCI', 'SOC', 'ICT'];
    const starts = ['08:00', '09:10', '10:20', '11:30', '13:30'];
    const ends = ['08:50', '10:00', '11:10', '12:20', '14:20'];
    return [
      for (var d = 0; d < days.length; d++)
        for (var s = 0; s < starts.length; s++)
          {
            'id': 'SLOT-$d-$s',
            'classId': 'JHS2A',
            'weekday': days[d],
            'start': starts[s],
            'end': ends[s],
            'subjectId': subjects[s % subjects.length],
            'teacherId': 'USR-TCH-001',
          },
    ];
  }

  List<Map<String, dynamic>> _seedResourcesJson() => const [
        {
          'id': 'RES-001',
          'subjectId': 'MATH',
          'classId': 'JHS2A',
          'kind': 'notes',
          'title': 'Fractions — Class Notes',
          'topic': 'Fractions',
          'body': 'A fraction has a numerator and a denominator. To add or '
              'subtract fractions, find a common denominator first.',
          'addedBy': 'Ms. Efua Mensah',
          'addedOn': '2026-09-01',
        },
        {
          'id': 'RES-002',
          'subjectId': 'MATH',
          'classId': 'JHS2A',
          'kind': 'worksheet',
          'title': 'Equivalent Fractions Worksheet',
          'topic': 'Fractions',
          'body': 'Simplify to lowest terms: 4/8, 6/12, 9/15, 12/20, 8/10. '
              'Show your working in the box.',
          'addedBy': 'Ms. Efua Mensah',
          'addedOn': '2026-09-02',
        },
        {
          'id': 'RES-003',
          'subjectId': 'ENG',
          'classId': 'JHS2A',
          'kind': 'notes',
          'title': 'Parts of Speech — Quick Reference',
          'topic': 'Grammar',
          'body': 'Nouns name things, verbs show action, adjectives describe '
              'nouns, and adverbs modify verbs or other adjectives.',
          'addedBy': 'Mr. Kwame Boateng',
          'addedOn': '2026-09-03',
        },
        {
          'id': 'RES-004',
          'subjectId': 'SCI',
          'classId': 'JHS2A',
          'kind': 'video',
          'title': 'The Water Cycle — Watch & Learn',
          'topic': 'Ecology',
          'body': 'Evaporation, condensation, precipitation and collection. '
              'Watch with your class, then answer three questions.',
          'addedBy': 'Ms. Efua Mensah',
          'addedOn': '2026-09-04',
        },
        {
          'id': 'RES-005',
          'subjectId': 'SOC',
          'classId': 'JHS2A',
          'kind': 'lessonPlan',
          'title': 'Map Skills — Lesson Plan',
          'topic': 'Map Reading',
          'body': 'Objective: read a simple map key. Starter: show a street '
              'map. Main: locate landmarks. Plenary: draw a classroom map.',
          'addedBy': 'Mr. Kwame Boateng',
          'addedOn': '2026-09-05',
        },
      ];

  List<Map<String, dynamic>> _seedSafetyPacksJson() => const [
        {
          'id': 'SAFE-001',
          'title': 'Road Safety',
          'topic': 'Traffic & Road Safety',
          'audience': 'STUDENT',
          'lessons': [
            'Look right, look left, look right again before crossing.',
            'Use the zebra crossing or pedestrian bridge where available.',
            'Never play on or near the road — use the pavement or field.',
            'Wear something bright in the evening so drivers can see you.',
          ],
          'quizQuestions': [
            'You should look left, right and left again before crossing.',
            'Playing football on the road is safe when no cars are visible.',
            'Crossing at a zebra crossing is safer than crossing elsewhere.',
          ],
          'quizAnswers': ['true', 'false', 'true'],
        },
        {
          'id': 'SAFE-002',
          'title': 'Fire Safety',
          'topic': 'Fire & Emergency',
          'audience': 'STUDENT',
          'lessons': [
            'If you smell smoke, tell an adult and leave the building.',
            'In a fire, crawl low and use the nearest exit if it is clear.',
            'Never hide under a bed or in a cupboard during a fire.',
            'Stop, drop and roll if your clothes catch fire.',
          ],
          'quizQuestions': [
            'You should hide under your bed during a school fire.',
            'Crawling low helps you breathe better in smoky rooms.',
            'Stop, drop and roll is the drill if clothes catch fire.',
          ],
          'quizAnswers': ['false', 'true', 'true'],
        },
        {
          'id': 'SAFE-003',
          'title': 'Stranger Danger',
          'topic': 'Personal Safety',
          'audience': 'STUDENT',
          'lessons': [
            'A stranger is anyone you do not know well, even if friendly.',
            'Never accept sweets, gifts or rides from a stranger.',
            'If a stranger approaches, move away and tell a trusted adult.',
            'Know your full name, address and an emergency contact number.',
          ],
          'quizQuestions': [
            'It is okay to accept a ride from a friendly stranger.',
            'You should tell a trusted adult if a stranger approaches you.',
            'Knowing your address helps you get home safely.',
          ],
          'quizAnswers': ['false', 'true', 'true'],
        },
      ];
}
