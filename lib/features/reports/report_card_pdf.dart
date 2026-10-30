import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/models/assessment.dart';
import '../../core/models/class_ladder.dart';
import '../../core/models/class_room.dart';
import '../../core/models/grading.dart';
import '../../core/models/school.dart';
import '../../core/models/school_term.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import 'reporting_service.dart';

// ---------------------------------------------------------------------------
// Template identity
// ---------------------------------------------------------------------------

/// The three print-ready report-card layouts shipped with SOLVANTA.
///
/// Every template renders exactly the same [ReportCardData], so the picker can
/// swap layouts (and the live preview) without touching the data layer.
enum ReportCardTemplate {
  /// Ghanaian (GES) terminal report: crest masthead, class score / exam score
  /// grid, 1–9 grades with subject positions, conduct lines and grading key.
  classic('Terminal report'),

  /// Airy: white masthead, navy rules, per-subject bars, oversized overall.
  modern('Modern'),

  /// Ghanaian academic transcript: particulars, subject × term record,
  /// grading key and the headteacher's certification.
  transcript('Transcript');

  const ReportCardTemplate(this.label);

  /// Picker label shown under the preview and on the chips.
  final String label;
}

// ---------------------------------------------------------------------------
// Grading — each school's own scheme for the student's class
// ---------------------------------------------------------------------------

/// [scheme]'s aggregate: the grades of its core subjects plus its best
/// `bestOthers` other subjects, summed (lower is better). `null` when the
/// scheme prints no aggregate or the card doesn't have enough grades yet.
int? schemeAggregate(GradingScheme scheme, List<SubjectResult> subjects) {
  if (!scheme.showAggregate) return null;
  final cores = <int>[];
  final others = <int>[];
  for (final s in subjects) {
    final g = int.tryParse(s.termGrade ?? '');
    if (g == null) continue;
    (scheme.coreSubjects.contains(s.subjectId) ? cores : others).add(g);
  }
  others.sort();
  if (cores.length < scheme.coreSubjects.length ||
      others.length < scheme.bestOthers ||
      cores.length + scheme.bestOthers == 0) {
    return null;
  }
  return [...cores, ...others.take(scheme.bestOthers)]
      .fold<int>(0, (a, b) => a + b);
}

/// `Aggregate (best 6)` — the count of subjects [scheme] sums.
String aggregateLabel(GradingScheme scheme) =>
    'Aggregate (best ${scheme.coreSubjects.length + scheme.bestOthers})';

/// `40%` — a weight without a needless `.0`.
String weightLabel(double w) =>
    '${w == w.roundToDouble() ? w.toInt() : w.toStringAsFixed(1)}%';

/// 1, 2 or 3 from a term name (`Term 2`, `Second Term` → 2); 1 if unclear.
int termNumber(String name) {
  final n = name.toLowerCase();
  final digit = RegExp(r'\d').firstMatch(n);
  if (digit != null) return int.parse(digit.group(0)!);
  if (n.contains('third')) return 3;
  if (n.contains('second')) return 2;
  return 1;
}

/// One term on the year chart: its name and average out of 100 (`null` when
/// nothing was marked).
class YearTerm {
  const YearTerm(this.name, this.average);

  final String name;
  final double? average;
}

/// A student's academic year so far: each term out of 100, a total out of
/// 100 × terms, and the year average — the figure promotion is decided on.
class YearProgress {
  const YearProgress(this.terms);

  final List<YearTerm> terms;

  List<double> get _marked => [
        for (final t in terms)
          if (t.average != null) t.average!,
      ];

  /// Sum of the term averages (`215.5`), or `null` with none marked.
  double? get total =>
      _marked.isEmpty ? null : _marked.reduce((a, b) => a + b);

  /// `300` for three marked terms.
  int get outOf => _marked.length * 100;

  /// Mean of the term averages, or `null` with none marked.
  double? get average => total == null ? null : total! / _marked.length;

  /// `(68.5 + 72.0 + 75.0) ÷ 3 = 71.8` — how [average] is worked out.
  String get formula {
    final a = average;
    if (a == null) return '';
    final parts = _marked.map((m) => m.toStringAsFixed(1)).join(' + ');
    return _marked.length == 1
        ? '${_marked.single.toStringAsFixed(1)} (one term so far)'
        : '($parts) ÷ ${_marked.length} = ${a.toStringAsFixed(1)}';
  }
}

/// `1st`, `2nd`, `3rd`, `11th`, `22nd`…
String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `2026-12-18` → `18 Dec 2026`; anything unparseable comes back as is.
String longDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

// ---------------------------------------------------------------------------
// Shared data model — what all three templates agree to render
// ---------------------------------------------------------------------------

/// One subject's aggregated result on a report card.
class SubjectResult {
  const SubjectResult({
    required this.subjectId,
    required this.name,
    required this.average,
    required this.grade,
    required this.marked,
    required this.of,
    this.classScore,
    this.examScore,
    this.total,
    this.partial = false,
    this.position,
    this.positionOf = 0,
    this.termGrade,
    this.termRemark = '',
  });

  /// Curriculum code (`MATH`, `ENG`, …).
  final String subjectId;

  /// Display name for [subjectId] (`Mathematics`).
  final String name;

  /// Mean percentage across marked work, or `null` when nothing is marked.
  final double? average;

  /// Letter grade for [average] (`A`–`E`), or `–` when unmarked.
  final String grade;

  /// How many of the [of] assessments carry a mark.
  final int marked;
  final int of;

  /// Class work scaled to the scheme's class weight, or `null` when none is
  /// marked.
  final double? classScore;

  /// End-of-term exam scaled to the scheme's exam weight, or `null` when not
  /// marked.
  final double? examScore;

  /// Terminal total out of 100, or `null` when nothing is marked.
  final double? total;

  /// True when only one of class score / exam is in, so [total] is that
  /// component's percentage rather than the weighted sum.
  final bool partial;

  /// Position in class for this subject, or `null` when unranked.
  final int? position;
  final int positionOf;

  /// The school's grade for [total] (`1`, `A1`, `B`…), or `null` when
  /// unmarked, and that band's remark (`Highest`, `Credit`…).
  final String? termGrade;
  final String termRemark;

  /// Print-safe label for [average] — `78.5%`, or `–` when unmarked.
  String get averageLabel =>
      average == null ? '-' : '${average!.toStringAsFixed(1)}%';

  String get classScoreLabel =>
      classScore == null ? '-' : classScore!.toStringAsFixed(1);
  String get examScoreLabel =>
      examScore == null ? '-' : examScore!.toStringAsFixed(1);

  /// `78.5`, `78.5*` when [partial], or `–`.
  String get totalLabel =>
      total == null ? '-' : '${total!.toStringAsFixed(1)}${partial ? '*' : ''}';

  /// `2nd`, or `–` when unranked.
  String get positionLabel => position == null ? '-' : ordinal(position!);
}

/// Attendance for the term, in school days.
class ReportAttendance {
  const ReportAttendance({required this.daysTotal, required this.daysPresent});

  /// Days recorded for the student (present, late, absent, excused).
  final int daysTotal;

  /// Days counted as present (present + late), matching the exports.
  final int daysPresent;

  /// `58/60 days present`, or `–` when there is no attendance to show.
  String get label =>
      daysTotal == 0 ? '-' : '$daysPresent/$daysTotal days present';

  /// Percentage of days present, or `null` when nothing is recorded.
  double? get rate => daysTotal == 0 ? null : 100 * daysPresent / daysTotal;
}

/// One term's headline result — the rows of the transcript summary table.
class TermRecord {
  const TermRecord({
    required this.termLabel,
    required this.overall,
    required this.grade,
    required this.rank,
    required this.classSize,
    this.subjects = const [],
    this.aggregate,
  });

  /// `Term 1 · 2026/2027`.
  final String termLabel;

  /// Overall average for the term, or `null` when nothing was marked.
  final double? overall;

  /// Letter grade for [overall].
  final String grade;

  /// Class position for the term, or `null` when unranked.
  final int? rank;

  /// How many classmates were ranked that term.
  final int classSize;

  /// That term's subject results — the columns of the transcript record.
  final List<SubjectResult> subjects;

  /// That term's aggregate, or `null`.
  final int? aggregate;
}

/// The single source of truth every report-card template renders.
///
/// Built once by [ReportCardDataBuilder.build] and handed to both the on-screen
/// preview and [buildReportCardPdf], so the preview and the printed page can
/// never disagree.
class ReportCardData {
  const ReportCardData({
    required this.studentName,
    required this.studentId,
    required this.admissionNo,
    required this.classId,
    required this.schoolName,
    required this.schoolMotto,
    required this.schoolContact,
    required this.termLabel,
    required this.subjects,
    required this.overall,
    required this.overallGrade,
    required this.rank,
    required this.classSize,
    required this.attendance,
    required this.remark,
    required this.teacherName,
    required this.history,
    required this.generatedAt,
    this.gender = '',
    this.dateOfBirth = '',
    this.admissionDate = '',
    this.studentStatus = '',
    this.termName = '',
    this.academicYear = '',
    this.vacationDate = '',
    this.promotedTo,
    this.termNumber = 1,
    this.outcome,
    this.year = const YearProgress([]),
    this.interventionNeeded = false,
    this.rollSize = 0,
    this.aggregate,
    this.scheme = gesBasicPreset,
  });

  final String studentName;
  final String studentId;
  final String admissionNo;
  final String classId;
  final String schoolName;
  final String schoolMotto;
  final String schoolContact;
  final String termLabel;

  /// Per-subject rows, sorted by name.
  final List<SubjectResult> subjects;

  /// Mean across every marked assessment, or `null` when nothing is marked.
  final double? overall;
  final String overallGrade;

  /// Class position, or `null` when the student could not be ranked.
  final int? rank;
  final int classSize;

  final ReportAttendance? attendance;

  /// Neutral, text-only class teacher's remark (never colour-coded).
  final String remark;

  /// Class teacher's name for the signature block (may be empty).
  final String teacherName;

  /// Prior terms — the transcript template's summary table. Model-ready for
  /// multi-term history; today it carries the current term only.
  final List<TermRecord> history;

  /// When this card was built, printed in the footer.
  final DateTime generatedAt;

  final String gender;

  /// `yyyy-MM-dd`, or `''` when not on record.
  final String dateOfBirth;
  final String admissionDate;
  final String studentStatus;

  /// `Term 1` and `2026/2027` — printed separately on Ghanaian cards.
  final String termName;
  final String academicYear;

  /// Last day of term (`yyyy-MM-dd`).
  final String vacationDate;

  /// The class the student is promoted to — set only when the Term 3
  /// [outcome] is [YearOutcome.promoted].
  final String? promotedTo;

  /// 1, 2 or 3 — from the term's name.
  final int termNumber;

  /// The end-of-year decision on the Term 3 card, or `null` (other terms, or
  /// the school decides by hand).
  final YearOutcome? outcome;

  /// This academic year's terms so far — the progress chart from Term 2 on.
  final YearProgress year;

  /// The year average so far is under the scheme's parent-meeting mark.
  final bool interventionNeeded;

  /// Students on the class register ("No. on roll").
  final int rollSize;

  /// The scheme's aggregate (lower is better), or `null`.
  final int? aggregate;

  /// The school's grading scheme for this student's class — its weights
  /// head the marks table and its bands make the grading key.
  final GradingScheme scheme;

  /// `2nd`, or `–` when unranked.
  String get positionLabel => rank == null ? '-' : ordinal(rank!);

  /// Sum of subject totals (`452.5`), or `null` when nothing is marked.
  double? get totalScore {
    final t = subjects.where((s) => s.total != null);
    return t.isEmpty ? null : t.fold<double>(0, (a, s) => a + s.total!);
  }

  /// Number of subjects with a total — the denominator of [totalScore].
  int get gradedSubjects => subjects.where((s) => s.total != null).length;

  /// True when any subject total is class work or exam only.
  bool get hasPartial => subjects.any((s) => s.partial);

  /// `2 of 6`, or `–` when unranked.
  String get rankLabel =>
      rank == null || classSize == 0 ? '-' : '$rank of $classSize';

  /// `86.0%`, or `–` when nothing is marked.
  String get overallLabel =>
      overall == null ? '-' : '${overall!.toStringAsFixed(1)}%';
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// Turns raw assessment data into [ReportCardData] — the aggregates, the class
/// rank and the teacher's remark live here so all three templates share them.
class ReportCardDataBuilder {
  const ReportCardDataBuilder._();

  /// Builds the report card for [student] for [term].
  ///
  /// Only assessments dated inside [term] count (undated ones are taken as
  /// this term's). [roster] is walked for the class positions; [pastTerms]
  /// adds earlier columns to the transcript; [attendance] is optional so a
  /// card still renders with no roll data — the caller scopes it to [term].
  /// Scores and grades follow the scheme [grading] sets for the class (found
  /// through [classes]); without one, the GES default.
  static ReportCardData build({
    required Student student,
    required School school,
    required SchoolTerm term,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    required List<Student> roster,
    List<FinishedTerm> pastTerms = const [],
    String teacherName = '',
    ({int total, int present})? attendance,
    GradingConfig? grading,
    List<ClassRoom> classes = const [],
  }) {
    final config = grading ?? GradingConfig.fallback;
    final inTerm = [
      for (final a in assessments)
        if (a.date.isEmpty || term.contains(a.date)) a,
    ];
    // The class the term was sat in: read off the student's own marked work,
    // so a card re-printed after end-of-year promotion (JHS2A → JHS3A)
    // still reports the JHS2A term. Their current class when nothing is
    // marked yet.
    final termClass = _classSatIn(student, inTerm, subs) ?? student.classId;
    final scheme = config.schemeFor(termClass, classes);
    final satTermClass = {
      for (final a in inTerm)
        if (a.classId == termClass)
          for (final sub in subs)
            if (sub.assessmentId == a.id) sub.studentId,
    };
    final classmates = [
      for (final s in roster)
        if (s.classId == termClass || satTermClass.contains(s.id)) s,
    ];
    final current = _termResult(
      scheme: scheme,
      student: student,
      classId: termClass,
      assessments: inTerm,
      subs: subs,
      cohort: classmates,
    );

    final att = attendance == null || attendance.total == 0
        ? null
        : ReportAttendance(
            daysTotal: attendance.total,
            daysPresent: attendance.present,
          );

    // Earlier terms, oldest first; this academic year's make the year view.
    final past = [
      for (final f in [...pastTerms]
        ..sort((a, b) => a.term.start.compareTo(b.term.start)))
        if (f.term.start != term.start)
          (
            term: f.term,
            // Graded as it was awarded: the set-up in force when it ended.
            record: _pastRecord(
              student,
              f.term,
              assessments,
              subs,
              roster,
              f.grading,
              classes,
            ),
          ),
    ];
    final number = termNumber(term.name);
    final year = YearProgress([
      for (final p in past)
        if (p.term.year == term.year)
          YearTerm(p.term.name, p.record?.overall),
      YearTerm(term.name, current.overall),
    ]);
    final yearAverage = year.average;

    // Term 3 settles the year by the school's thresholds for this class.
    final nextClass = nextClassId(termClass, classes);
    final outcome = number == 3 && yearAverage != null
        ? scheme.outcomeFor(yearAverage, finalClass: nextClass == null)
        : null;
    final intervention =
        number >= 2 && yearAverage != null && scheme.needsIntervention(yearAverage);

    final remark = _remarkFor(
      student.firstName,
      current.overall,
      current.rank,
      current.ranked,
      current.subjects,
      outcome: outcome,
      nextClass: nextClass,
      classLevel: classLevel(termClass),
      intervention: intervention,
    );

    return ReportCardData(
      studentName: student.fullName,
      studentId: student.id,
      admissionNo: student.admissionNo,
      classId: termClass,
      schoolName: school.name,
      schoolMotto: school.motto,
      schoolContact: [
        school.address,
        school.phone,
      ].where((x) => x.trim().isNotEmpty).join(' · '),
      termLabel: term.label,
      subjects: current.subjects,
      overall: current.overall,
      overallGrade: current.overall == null
          ? '-'
          : scheme.bandFor(current.overall!).grade,
      rank: current.rank,
      classSize: current.ranked,
      attendance: att,
      remark: remark,
      teacherName: teacherName,
      history: [
        for (final p in past) ?p.record,
        current.record(term.label),
      ],
      generatedAt: DateTime.now(),
      gender: student.gender,
      dateOfBirth: student.dateOfBirth,
      admissionDate: student.admissionDate,
      studentStatus: student.status,
      termName: term.name,
      academicYear: term.year,
      vacationDate: term.end,
      termNumber: number,
      promotedTo: outcome == YearOutcome.promoted ? nextClass : null,
      outcome: outcome,
      year: year,
      interventionNeeded: intervention,
      rollSize: classmates.length,
      aggregate: current.aggregate,
      scheme: scheme,
    );
  }

  /// [student]'s record for a finished term, or `null` when they have no
  /// marked work in it. The student may have been in another class then, so
  /// that class is read off their own submissions, and positions are taken
  /// among everyone who sat that class's work in the term, graded by the
  /// scheme that class follows.
  static TermRecord? _pastRecord(
    Student student,
    SchoolTerm term,
    List<Assessment> assessments,
    List<AssessmentSubmission> subs,
    List<Student> roster,
    GradingConfig grading,
    List<ClassRoom> classes,
  ) {
    final inTerm = [
      for (final a in assessments)
        if (term.contains(a.date)) a,
    ];
    final classId = _classSatIn(student, inTerm, subs);
    if (classId == null) return null;
    final classIds = {
      for (final a in inTerm)
        if (a.classId == classId) a.id,
    };
    final sat = {
      for (final sub in subs)
        if (classIds.contains(sub.assessmentId)) sub.studentId,
    };
    final result = _termResult(
      scheme: grading.schemeFor(classId, classes),
      student: student,
      classId: classId,
      assessments: inTerm,
      subs: subs,
      cohort: [
        for (final s in roster)
          if (sat.contains(s.id)) s,
      ],
    );
    return result.overall == null ? null : result.record(term.label);
  }

  /// The class [student] sat [inTerm]'s work in — the one most of their
  /// marked papers belong to — or `null` when none is marked.
  static String? _classSatIn(
    Student student,
    List<Assessment> inTerm,
    List<AssessmentSubmission> subs,
  ) {
    final byId = {for (final a in inTerm) a.id: a};
    final counts = <String, int>{};
    for (final sub in subs) {
      final a = byId[sub.assessmentId];
      if (a == null || sub.studentId != student.id) continue;
      counts.update(a.classId, (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.isEmpty) return null;
    return counts.entries.reduce((x, y) => y.value > x.value ? y : x).key;
  }

  /// One term's subjects, totals and positions for [student] in [classId].
  ///
  /// Positions follow Ghanaian practice: overall by total score (the sum of
  /// subject totals), each subject by its own total. Ties share a position.
  static _TermResult _termResult({
    required GradingScheme scheme,
    required Student student,
    required String classId,
    required List<Assessment> assessments,
    required List<AssessmentSubmission> subs,
    required List<Student> cohort,
  }) {
    final svc = ReportingService();
    final rows = svc.rowsFor(
      student: student,
      assessments: assessments,
      subs: subs,
      classId: classId,
    );
    final summaries = svc.subjectsFor(rows: rows);
    final scores = _terminalScores(rows, scheme);
    final myTotal = _sumTotals(scores);

    var ahead = 0;
    var ranked = 0;
    final subjectAhead = <String, int>{};
    final subjectRanked = <String, int>{};
    for (final mate in cohort) {
      final mateScores = _terminalScores(
        svc.rowsFor(
          student: mate,
          assessments: assessments,
          subs: subs,
          classId: classId,
        ),
        scheme,
      );
      final mateTotal = _sumTotals(mateScores);
      if (mateTotal != null) {
        ranked++;
        if (myTotal != null && mateTotal > myTotal) ahead++;
      }
      for (final e in mateScores.entries) {
        final t = e.value.total;
        if (t == null) continue;
        subjectRanked.update(e.key, (n) => n + 1, ifAbsent: () => 1);
        final mine = scores[e.key]?.total;
        if (mine != null && t > mine) {
          subjectAhead.update(e.key, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }

    final subjects = [
      for (final s in summaries)
        SubjectResult(
          subjectId: s.subjectId,
          name: subjectName(s.subjectId),
          average: s.average,
          grade: s.average == null ? '-' : scheme.bandFor(s.average!).grade,
          marked: s.attempts,
          of: s.of,
          classScore: scores[s.subjectId]?.classScore,
          examScore: scores[s.subjectId]?.examScore,
          total: scores[s.subjectId]?.total,
          partial: scores[s.subjectId]?.partial ?? false,
          position: scores[s.subjectId]?.total == null
              ? null
              : (subjectAhead[s.subjectId] ?? 0) + 1,
          positionOf: subjectRanked[s.subjectId] ?? 0,
          termGrade: _band(scheme, scores[s.subjectId]?.total)?.grade,
          termRemark: _band(scheme, scores[s.subjectId]?.total)?.remark ?? '',
        ),
    ]..sort((a, b) => a.name.compareTo(b.name));
    final graded = subjects.where((s) => s.total != null).length;

    return _TermResult(
      scheme: scheme,
      subjects: subjects,
      // The average printed beside "Total score" — total ÷ subjects.
      overall: myTotal == null ? null : myTotal / graded,
      rank: myTotal == null ? null : ahead + 1,
      ranked: ranked,
      aggregate: schemeAggregate(scheme, subjects),
    );
  }

  /// [scheme]'s band for [total], or `null` when there is no total.
  static GradeBand? _band(GradingScheme scheme, double? total) =>
      total == null ? null : scheme.bandFor(total);

  /// Sum of subject totals, or `null` when no subject has one.
  static double? _sumTotals(Map<String, _Terminal> scores) {
    final totals = [
      for (final t in scores.values)
        if (t.total != null) t.total!,
    ];
    return totals.isEmpty ? null : totals.reduce((a, b) => a + b);
  }

  /// Per-subject class score, exam score and total, weighted as [scheme]
  /// says (30/70, 40/60…). The exam is the end-of-term examination; every
  /// other marked piece of work is class work. With only one side marked,
  /// the total is that side's percentage and flagged [_Terminal.partial].
  static Map<String, _Terminal> _terminalScores(
    List<ReportCardRow> rows,
    GradingScheme scheme,
  ) {
    double? mean(Iterable<double> xs) =>
        xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
    final out = <String, _Terminal>{};
    final bySubject = <String, List<ReportCardRow>>{};
    for (final r in rows) {
      if (r.pct != null) (bySubject[r.subjectId] ??= []).add(r);
    }
    for (final e in bySubject.entries) {
      final classPct = mean(
        e.value
            .where((r) => r.type != AssessmentType.endTerm)
            .map((r) => r.pct!),
      );
      final examPct = mean(
        e.value
            .where((r) => r.type == AssessmentType.endTerm)
            .map((r) => r.pct!),
      );
      final cs =
          classPct == null ? null : classPct * scheme.classWeight / 100;
      final es = examPct == null ? null : examPct * scheme.examWeight / 100;
      out[e.key] = (cs != null && es != null)
          ? _Terminal(cs, es, cs + es, false)
          : _Terminal(cs, es, classPct ?? examPct, true);
    }
    return out;
  }

  /// A neutral remark built from the numbers — strengths and position only,
  /// never green/red verdicts (grades stay black on white in print).
  static String _remarkFor(
    String firstName,
    double? overall,
    int? rank,
    int classSize,
    List<SubjectResult> subjects, {
    YearOutcome? outcome,
    String? nextClass,
    String classLevel = '',
    bool intervention = false,
  }) {
    final year = switch (outcome) {
      YearOutcome.promoted => ' Promoted to ${nextClass ?? 'the next class'}.',
      YearOutcome.repeated => ' To repeat $classLevel next year.',
      YearOutcome.review => ' Promotion will be decided by the headteacher.',
      YearOutcome.completed => ' Has completed this stage of school.',
      null => '',
    };
    final meet = intervention
        ? " We would like to meet $firstName's parents to plan extra support."
        : '';
    if (overall == null) {
      return 'No marks have been recorded for $firstName this term yet. '
          'The report will be completed once assessments are marked.'
          '$year$meet';
    }
    final effort = overall >= 75
        ? 'a strong, consistent effort'
        : overall >= 55
        ? 'a steady effort with clear room to build on'
        : 'an honest effort; further practice will build confidence';
    final ranked = subjects.where((s) => s.average != null).toList()
      ..sort((a, b) => (b.average ?? 0).compareTo(a.average ?? 0));
    final strength = ranked.isEmpty
        ? ''
        : ' ${ranked.first.name} is the strongest area '
              '(${ranked.first.averageLabel}).';
    final place = rank == null || classSize == 0
        ? ''
        : ' Position: ${ordinal(rank)} out of $classSize.';
    return '$firstName has shown $effort this term, averaging '
        '${overall.toStringAsFixed(1)}%.'
        '$strength$place$year$meet';
  }
}

/// One student's results for one term.
class _TermResult {
  const _TermResult({
    required this.scheme,
    required this.subjects,
    required this.overall,
    required this.rank,
    required this.ranked,
    required this.aggregate,
  });

  final GradingScheme scheme;
  final List<SubjectResult> subjects;
  final double? overall;
  final int? rank;
  final int ranked;
  final int? aggregate;

  TermRecord record(String label) => TermRecord(
    termLabel: label,
    overall: overall,
    grade: overall == null ? '-' : scheme.bandFor(overall!).grade,
    rank: rank,
    classSize: ranked,
    subjects: subjects,
    aggregate: aggregate,
  );
}

/// One subject's terminal-report scores for one student.
class _Terminal {
  const _Terminal(this.classScore, this.examScore, this.total, this.partial);

  final double? classScore;
  final double? examScore;
  final double? total;
  final bool partial;
}

// ---------------------------------------------------------------------------
// PDF palette — derived from the const brand tokens (never raw hex).
// Printed pages are always white, so the light palette is the correct choice
// regardless of the app's current brightness.
// ---------------------------------------------------------------------------

final PdfColor _navy = PdfColor.fromInt(AppTheme.brand.toARGB32());
final PdfColor _navyLight = PdfColor.fromInt(AppTheme.brandLight.toARGB32());
final PdfColor _navy100 = PdfColor.fromInt(AppTheme.navy100.toARGB32());
final PdfColor _navy50 = PdfColor.fromInt(AppTheme.navy50.toARGB32());
final PdfColor _gold = PdfColor.fromInt(AppTheme.gold.toARGB32());
final PdfColor _paper = PdfColor.fromInt(AppPalette.light.surface.toARGB32());
final PdfColor _ink = PdfColor.fromInt(AppPalette.light.ink.toARGB32());
final PdfColor _muted = PdfColor.fromInt(AppPalette.light.body.toARGB32());
final PdfColor _hair = PdfColor.fromInt(AppPalette.light.border.toARGB32());

// Text styles are runtime `final`s rather than `const`: pdf's `TextStyle`
// const-ctor evaluates its initializer list at compile time, and the analyzer
// rejects `const` for every style that passes `fontWeight: FontWeight.bold`.
// They are also referenced only from runtime widget arguments.
final pw.TextStyle _kvValue = pw.TextStyle(
  fontSize: 8.5,
  color: PdfColors.black,
);
final pw.TextStyle _statValue = pw.TextStyle(
  fontSize: 11,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);
final pw.TextStyle _grade = pw.TextStyle(
  fontSize: 9.5,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);
final pw.TextStyle _score = pw.TextStyle(
  fontSize: 20,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);
final pw.TextStyle _kicker = pw.TextStyle(
  fontSize: 9,
  letterSpacing: 1.6,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);

final pw.TextStyle _kvLabel = pw.TextStyle(
  fontSize: 8.5,
  fontWeight: pw.FontWeight.bold,
  color: _ink,
);
final pw.TextStyle _section = pw.TextStyle(
  fontSize: 11,
  fontWeight: pw.FontWeight.bold,
  color: _navy,
);
final pw.TextStyle _body = pw.TextStyle(fontSize: 8.5, color: PdfColors.black);
final pw.TextStyle _mutedText = pw.TextStyle(fontSize: 7.5, color: _muted);
final pw.TextStyle _statLabel = pw.TextStyle(
  fontSize: 6.5,
  letterSpacing: 0.8,
  color: _muted,
);
final pw.TextStyle _modernSchool = pw.TextStyle(
  fontSize: 14,
  fontWeight: pw.FontWeight.bold,
  color: _navy,
);
final pw.TextStyle _modernName = pw.TextStyle(
  fontSize: 15,
  fontWeight: pw.FontWeight.bold,
  color: _ink,
);
final pw.TextStyle _subjectName = pw.TextStyle(fontSize: 9, color: _ink);

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Renders [data] as a single-page A4 PDF in [template] and returns its bytes.
///
/// Pure Dart — no build context — so the caller can write the bytes to a file
/// and hand them to the share sheet.
Future<Uint8List> buildReportCardPdf(
  ReportCardData data,
  ReportCardTemplate template,
) async {
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (context) => switch (template) {
        ReportCardTemplate.classic => _terminalPage(data),
        ReportCardTemplate.modern => _modernPage(data),
        ReportCardTemplate.transcript => _transcriptPage(data),
      },
    ),
  );
  return doc.save();
}

// ---------------------------------------------------------------------------
// Shared building blocks
// ---------------------------------------------------------------------------

/// Section heading (`Subjects`, `Term record`, …).
pw.Widget _title(String text) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 12, bottom: 5),
  child: pw.Text(text, style: _section),
);

/// Compact statistic tile (Class / Rank / Attendance).
pw.Widget _stat(String label, String value) => pw.Expanded(
  child: pw.Container(
    margin: const pw.EdgeInsets.only(right: 6),
    padding: const pw.EdgeInsets.all(6),
    decoration: pw.BoxDecoration(
      color: _navy50,
      border: pw.Border.all(color: _navy100, width: 0.6),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label.toUpperCase(), style: _statLabel),
        pw.SizedBox(height: 2),
        pw.Text(value, style: _statValue),
      ],
    ),
  ),
);

/// Footer line, always centred.
pw.Widget _footer(ReportCardData d) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 12),
  child: pw.Text(
    'Generated by SOLVANTA · ${_iso(d.generatedAt)} · ${d.schoolName}',
    textAlign: pw.TextAlign.center,
    style: _mutedText,
  ),
);

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

// ---------------------------------------------------------------------------
// Ghanaian building blocks — shared by the terminal report and transcript
// ---------------------------------------------------------------------------

final pw.TextStyle _ghSchool = pw.TextStyle(
  fontSize: 15,
  fontWeight: pw.FontWeight.bold,
  color: _navy,
  letterSpacing: 0.6,
);
final pw.TextStyle _ghSmall = pw.TextStyle(fontSize: 7.5, color: _muted);
final pw.TextStyle _ghMotto = pw.TextStyle(
  fontSize: 8,
  fontStyle: pw.FontStyle.italic,
  color: _ink,
);
final pw.TextStyle _ghBanner = pw.TextStyle(
  fontSize: 10.5,
  fontWeight: pw.FontWeight.bold,
  letterSpacing: 2.2,
  color: PdfColors.white,
);
final pw.TextStyle _ghCrest = pw.TextStyle(
  fontSize: 12,
  fontWeight: pw.FontWeight.bold,
  color: _navy,
);
final pw.TextStyle _ghLabel = pw.TextStyle(
  fontSize: 7.5,
  fontWeight: pw.FontWeight.bold,
  color: _ink,
);
final pw.TextStyle _ghValue = pw.TextStyle(
  fontSize: 8.5,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);
final pw.TextStyle _ghTh = pw.TextStyle(
  fontSize: 6.8,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);
final pw.TextStyle _ghTd = pw.TextStyle(fontSize: 8, color: PdfColors.black);
final pw.TextStyle _ghTdBold = pw.TextStyle(
  fontSize: 8,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);
final pw.TextStyle _ghSection = pw.TextStyle(
  fontSize: 8,
  fontWeight: pw.FontWeight.bold,
  letterSpacing: 1.2,
  color: _navy,
);
final pw.TextStyle _ghKey = pw.TextStyle(fontSize: 6.2, color: PdfColors.black);
final pw.TextStyle _ghKeyGrade = pw.TextStyle(
  fontSize: 8,
  fontWeight: pw.FontWeight.bold,
  color: PdfColors.black,
);

/// Initials for the crest roundel (`Accra Academy School` → `AAS`).
String schoolInitials(String name) => name
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty && w[0].toUpperCase() != w[0].toLowerCase())
    .take(3)
    .map((w) => w[0].toUpperCase())
    .join();

/// `JUNIOR HIGH SCHOOL` for JHS classes, otherwise empty.
String schoolLevelFor(String classId) {
  final c = classId.toUpperCase();
  if (c.startsWith('JHS')) return 'JUNIOR HIGH SCHOOL';
  if (c.startsWith('SHS')) return 'SENIOR HIGH SCHOOL';
  if (c.startsWith('KG')) return 'KINDERGARTEN';
  if (c.startsWith('NURSERY') || c.startsWith('CRECHE')) return 'PRE-SCHOOL';
  // Standards-based names: Basic 1–6 is primary, Basic 7–9 is JHS.
  final basic = RegExp(r'^(?:B|BS|BASIC\s*)(\d+)').firstMatch(c);
  if (basic != null) {
    return int.parse(basic.group(1)!) <= 6
        ? 'PRIMARY SCHOOL'
        : 'JUNIOR HIGH SCHOOL';
  }
  if (RegExp(r'^(?:P|PRIMARY\s*)\d').hasMatch(c)) return 'PRIMARY SCHOOL';
  return '';
}

/// Double-ruled page frame every Ghanaian card is printed inside.
/// Width inside [_ghFrame]: A4 less the margin, both rules and padding.
final double _ghBodyWidth =
    PdfPageFormat.a4.width - 2 * 18 - 2 * 2.5 - 2 * 16 - 2 * (1.6 + 0.5);

/// The page body is laid out at full width and only scaled down when it is
/// taller than the frame (a long timetable plus the year chart), so nothing
/// at the foot of the card — signatures, grading key — is ever cut off.
pw.Widget _ghFrame(pw.Widget child) => pw.Container(
  color: _paper,
  padding: const pw.EdgeInsets.all(18),
  child: pw.Container(
    padding: const pw.EdgeInsets.all(2.5),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: _navy, width: 1.6),
    ),
    child: pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _navy, width: 0.5),
      ),
      child: pw.FittedBox(
        fit: pw.BoxFit.scaleDown,
        alignment: pw.Alignment.topCenter,
        child: pw.SizedBox(width: _ghBodyWidth, child: child),
      ),
    ),
  ),
);

/// Crest roundel · centred school name, contact and motto · photo box, then
/// the navy title banner with its gold rule.
pw.Widget _ghHeader(ReportCardData d, String title) {
  final level = schoolLevelFor(d.classId);
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Row(
        children: [
          pw.Container(
            width: 50,
            height: 50,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              shape: pw.BoxShape.circle,
              color: _navy50,
              border: pw.Border.all(color: _navy, width: 1.4),
            ),
            child: pw.Text(schoolInitials(d.schoolName), style: _ghCrest),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(
            child: pw.Column(
              children: [
                pw.Text(
                  d.schoolName.toUpperCase(),
                  textAlign: pw.TextAlign.center,
                  style: _ghSchool,
                ),
                if (d.schoolContact.isNotEmpty)
                  pw.Text(
                    d.schoolContact,
                    textAlign: pw.TextAlign.center,
                    style: _ghSmall,
                  ),
                if (d.schoolMotto.isNotEmpty)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 2),
                    child: pw.Text(
                      'Motto: ${d.schoolMotto}',
                      textAlign: pw.TextAlign.center,
                      style: _ghMotto,
                    ),
                  ),
              ],
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Container(
            width: 44,
            height: 52,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: _hair, width: 0.8),
            ),
            child: pw.Text('PHOTO', style: _ghSmall),
          ),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Container(
        color: _navy,
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        alignment: pw.Alignment.center,
        child: pw.Text(
          level.isEmpty ? title : '$level · $title',
          style: _ghBanner,
        ),
      ),
      pw.Container(height: 2, color: _gold),
    ],
  );
}

/// `Label: value` over a dotted rule — blank values leave a line to fill in
/// by hand, as on a printed card.
pw.Widget _ghField(String label, String value, {double labelWidth = 0}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.only(top: 5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          if (labelWidth > 0)
            pw.SizedBox(
              width: labelWidth,
              child: pw.Text(label, style: _ghLabel),
            )
          else
            pw.Text('$label ', style: _ghLabel),
          pw.Expanded(
            child: pw.Container(
              padding: const pw.EdgeInsets.only(left: 3, bottom: 1),
              decoration: pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(
                    color: _muted,
                    width: 0.6,
                    style: pw.BorderStyle.dotted,
                  ),
                ),
              ),
              child: pw.Text(value.isEmpty ? ' ' : value, style: _ghValue),
            ),
          ),
        ],
      ),
    );

/// Two [_ghField]s side by side.
pw.Widget _ghPair(String l1, String v1, String l2, String v2) => pw.Row(
  children: [
    pw.Expanded(child: _ghField(l1, v1, labelWidth: 76)),
    pw.SizedBox(width: 14),
    pw.Expanded(child: _ghField(l2, v2, labelWidth: 76)),
  ],
);

/// Small-caps section heading with a hairline under it.
pw.Widget _ghSectionTitle(String text) => pw.Container(
  margin: const pw.EdgeInsets.only(top: 10, bottom: 4),
  padding: const pw.EdgeInsets.only(bottom: 2),
  decoration: pw.BoxDecoration(
    border: pw.Border(bottom: pw.BorderSide(color: _navy, width: 0.8)),
  ),
  child: pw.Text(text, style: _ghSection),
);

final pw.TableBorder _ghGrid = pw.TableBorder.all(
  color: PdfColors.black,
  width: 0.6,
);

pw.Widget _ghCell(
  String text, {
  pw.TextStyle? style,
  pw.TextAlign align = pw.TextAlign.center,
  PdfColor? fill,
}) => pw.Container(
  color: fill,
  padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4.5),
  child: pw.Text(text, textAlign: align, style: style ?? _ghTd),
);

/// The school's grading key for [scheme], printed at the foot of every card.
pw.Widget _ghGradingKey(GradingScheme scheme) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
  children: [
    pw.Text('GRADING SYSTEM', style: _ghSection),
    pw.SizedBox(height: 3),
    pw.Table(
      border: _ghGrid,
      columnWidths: {
        for (var i = 0; i < scheme.bands.length; i++)
          i: const pw.FlexColumnWidth(1),
      },
      children: [
        pw.TableRow(
          children: [
            for (final (i, b) in scheme.bands.indexed)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                child: pw.Column(
                  children: [
                    pw.Text(b.grade, style: _ghKeyGrade),
                    pw.Text(scheme.rangeOf(i), style: _ghKey),
                    pw.Text(
                      b.remark,
                      textAlign: pw.TextAlign.center,
                      style: _ghKey,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    ),
  ],
);

final pw.BoxDecoration _ghDotted = pw.BoxDecoration(
  border: pw.Border(
    bottom: pw.BorderSide(
      color: _muted,
      width: 0.6,
      style: pw.BorderStyle.dotted,
    ),
  ),
);

/// A bold label over dotted writing lines; [text] (if any) fills the first,
/// the rest stay blank for the teacher's pen.
pw.Widget _ghLines(String label, String text, {int lines = 2}) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 7),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Text(label, style: _ghLabel),
      if (text.isNotEmpty)
        pw.Container(
          padding: const pw.EdgeInsets.only(top: 3, bottom: 1),
          decoration: _ghDotted,
          child: pw.Text(text, style: _body),
        ),
      for (var i = text.isEmpty ? 0 : 1; i < lines; i++)
        pw.Container(height: 15, decoration: _ghDotted),
    ],
  ),
);

/// Ruled signature with its caption.
pw.Widget _ghSignature(String caption, String name) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.center,
  children: [
    pw.Text(name.isEmpty ? ' ' : name, style: _ghTdBold),
    pw.SizedBox(height: 2),
    pw.Container(height: 0.6, color: PdfColors.black),
    pw.SizedBox(height: 2),
    pw.Text(caption, style: _ghSmall),
  ],
);

/// Dashed roundel where the school stamp goes.
pw.Widget _ghStamp() => pw.Container(
  width: 58,
  height: 58,
  alignment: pw.Alignment.center,
  decoration: pw.BoxDecoration(
    shape: pw.BoxShape.circle,
    border: pw.Border.all(
      color: _muted,
      width: 0.7,
      style: pw.BorderStyle.dashed,
    ),
  ),
  child: pw.Text(
    'SCHOOL\nSTAMP',
    textAlign: pw.TextAlign.center,
    style: _ghSmall,
  ),
);

/// What the Term 3 "Promoted to:" line says: the class, or why there is
/// none. Blank where the school decides by hand, so it can be written in.
String endOfYearLabel(ReportCardData d) => switch (d.outcome) {
  YearOutcome.promoted => d.promotedTo ?? '',
  YearOutcome.repeated => 'Repeated - stays in ${classLevel(d.classId)}',
  YearOutcome.completed => 'Completed ${classLevel(d.classId)}',
  YearOutcome.review => 'Awaiting headteacher\'s decision',
  null => '',
};

String _num1(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// The bars of the year chart: Terms 1–3 (a term still to come shows empty)
/// and the year average.
List<({String label, double? value, bool year})> yearBars(YearProgress y) {
  final byNumber = {for (final t in y.terms) termNumber(t.name): t};
  return [
    for (var n = 1; n <= 3; n++)
      (
        label: byNumber[n]?.name ?? 'Term $n',
        value: byNumber[n]?.average,
        year: false,
      ),
    (label: 'Year avg.', value: y.average, year: true),
  ];
}

/// "Progress this year": each term's average as a bar beside the year
/// average, the sum that gives it, the school's thresholds and — on Term 3 —
/// the decision. Printed from Term 2 on.
pw.Widget _ghYearBlock(ReportCardData d) {
  const chartH = 52.0;
  const labelH = 10.0;
  final rules = d.scheme.yearRulesLine;
  final promote = d.scheme.promoteAt ?? d.scheme.repeatBelow;
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      _ghSectionTitle('PROGRESS THIS YEAR'),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 210,
            height: chartH + labelH + 12,
            child: pw.Stack(
              children: [
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    for (final b in yearBars(d.year))
                      pw.Column(
                        mainAxisAlignment: pw.MainAxisAlignment.end,
                        children: [
                          pw.Text(
                            b.value == null ? '-' : b.value!.toStringAsFixed(1),
                            style: _ghKeyGrade,
                          ),
                          pw.Container(
                            width: 28,
                            height: b.value == null
                                ? 0.6
                                : (chartH * b.value!.clamp(0, 100) / 100)
                                      .clamp(0.6, chartH)
                                      .toDouble(),
                            color: b.value == null
                                ? _hair
                                : (b.year ? _gold : _navy),
                          ),
                          pw.SizedBox(
                            height: labelH,
                            child: pw.Text(b.label, style: _ghKey),
                          ),
                        ],
                      ),
                  ],
                ),
                if (promote != null)
                  pw.Positioned(
                    left: 0,
                    right: 0,
                    bottom: labelH + chartH * promote / 100,
                    child: pw.Container(
                      decoration: pw.BoxDecoration(
                        border: pw.Border(
                          top: pw.BorderSide(
                            color: _muted,
                            width: 0.6,
                            style: pw.BorderStyle.dashed,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Year total: ${d.year.total!.toStringAsFixed(1)} out of '
                  '${d.year.outOf}',
                  style: _ghTdBold,
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'Year average = ${d.year.formula}',
                  style: _ghTd,
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'Each term counts its average out of 100; the year average '
                  'is their mean${promote == null ? '' : ' (dashed line: promotion mark)'}.',
                  style: _ghSmall,
                ),
                if (rules.isNotEmpty) pw.Text(rules, style: _ghSmall),
                if (d.outcome != null)
                  pw.Container(
                    margin: const pw.EdgeInsets.only(top: 4),
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: _navy, width: 0.8),
                    ),
                    child: pw.Text(
                      'END OF YEAR: ${d.outcome!.label.toUpperCase()}'
                      '${d.outcome == YearOutcome.promoted && d.promotedTo != null ? ' TO ${d.promotedTo}' : ''}',
                      style: _ghTdBold,
                    ),
                  ),
                if (d.interventionNeeded)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 3),
                    child: pw.Text(
                      'Parent meeting requested: the year average is below '
                      '${_num1(d.scheme.interventionBelow!)}.',
                      style: _ghTdBold,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Template 1 — Ghanaian terminal report
// ---------------------------------------------------------------------------

pw.Widget _terminalPage(ReportCardData d) => _ghFrame(
  pw.Column(
    mainAxisSize: pw.MainAxisSize.min,
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      _ghHeader(d, "PUPIL'S TERMINAL REPORT"),
      pw.SizedBox(height: 4),
      _ghField('Name of pupil:', d.studentName, labelWidth: 76),
      _ghPair('Admission No.:', d.admissionNo, 'Class:', d.classId),
      _ghPair('Term:', d.termName, 'Academic year:', d.academicYear),
      _ghPair(
        'No. on roll:',
        d.rollSize == 0 ? '' : '${d.rollSize}',
        'Position in class:',
        d.rank == null ? '' : '${d.positionLabel} out of ${d.classSize}',
      ),
      _ghPair(
        'Attendance:',
        d.attendance == null
            ? ''
            : '${d.attendance!.daysPresent} out of '
                  '${d.attendance!.daysTotal}',
        'Vacation date:',
        longDate(d.vacationDate),
      ),
      _ghPair(
        'Next term begins:',
        '',
        d.termNumber == 3 ? 'Promoted to:' : '',
        endOfYearLabel(d),
      ),
      pw.SizedBox(height: 10),
      _terminalTable(d),
      pw.SizedBox(height: 4),
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: pw.BoxDecoration(
          color: _navy50,
          border: pw.Border.all(color: PdfColors.black, width: 0.6),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Total score: ${d.totalScore == null ? '-' : '${d.totalScore!.toStringAsFixed(1)} out of ${d.gradedSubjects * 100}'}',
              style: _ghTdBold,
            ),
            pw.Text('Average: ${d.overallLabel}', style: _ghTdBold),
            if (d.scheme.showAggregate)
              pw.Text(
                '${aggregateLabel(d.scheme)}: ${d.aggregate?.toString() ?? '-'}',
                style: _ghTdBold,
              ),
          ],
        ),
      ),
      if (d.hasPartial)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 2),
          child: pw.Text(
            '* Only class work or only the examination is recorded for '
            'this subject; the total shown is that score out of 100.',
            style: _ghSmall,
          ),
        ),
      if (d.termNumber >= 2 && d.year.average != null) _ghYearBlock(d),
      pw.SizedBox(height: 4),
      pw.Row(
        children: [
          pw.Expanded(child: _ghField('Conduct:', '')),
          pw.SizedBox(width: 10),
          pw.Expanded(child: _ghField('Attitude:', '')),
          pw.SizedBox(width: 10),
          pw.Expanded(child: _ghField('Interest:', '')),
        ],
      ),
      pw.Row(
        children: [
          pw.Expanded(child: _ghField('Fees owing (GHS):', '')),
          pw.SizedBox(width: 14),
          pw.Expanded(child: _ghField("Next term's fees (GHS):", '')),
        ],
      ),
      _ghLines("Class teacher's remarks:", d.remark),
      _ghLines("Headteacher's remarks:", ''),
      pw.SizedBox(height: 26),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Expanded(
            child: _ghSignature("Class teacher's signature", d.teacherName),
          ),
          pw.SizedBox(width: 18),
          pw.Expanded(child: _ghSignature("Headteacher's signature", '')),
          pw.SizedBox(width: 18),
          _ghStamp(),
        ],
      ),
      pw.SizedBox(height: 10),
      _ghGradingKey(d.scheme),
      _footer(d),
    ],
  ),
);

/// Subject | Class score | Exam score | Total | Grade | Pos. | Remarks.
pw.Widget _terminalTable(ReportCardData d) => pw.Table(
  border: _ghGrid,
  columnWidths: const {
    0: pw.FlexColumnWidth(3.4),
    1: pw.FlexColumnWidth(1.15),
    2: pw.FlexColumnWidth(1.15),
    3: pw.FlexColumnWidth(1.15),
    4: pw.FlexColumnWidth(0.8),
    5: pw.FlexColumnWidth(0.8),
    6: pw.FlexColumnWidth(1.7),
  },
  defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
  children: [
    pw.TableRow(
      decoration: pw.BoxDecoration(color: _navy100),
      children: [
        _ghCell('SUBJECT', style: _ghTh, align: pw.TextAlign.left),
        _ghCell(
          'CLASS SCORE\n(${weightLabel(d.scheme.classWeight)})',
          style: _ghTh,
        ),
        _ghCell(
          'EXAM SCORE\n(${weightLabel(d.scheme.examWeight)})',
          style: _ghTh,
        ),
        _ghCell('TOTAL\n(100%)', style: _ghTh),
        _ghCell('GRADE', style: _ghTh),
        _ghCell('POS.', style: _ghTh),
        _ghCell('REMARKS', style: _ghTh),
      ],
    ),
    for (final s in d.subjects)
      pw.TableRow(
        children: [
          _ghCell(s.name, align: pw.TextAlign.left),
          _ghCell(s.classScoreLabel),
          _ghCell(s.examScoreLabel),
          _ghCell(s.totalLabel, style: _ghTdBold),
          _ghCell(s.termGrade ?? '-', style: _ghTdBold),
          _ghCell(s.positionLabel),
          _ghCell(s.termRemark.isEmpty ? '-' : s.termRemark),
        ],
      ),
  ],
);

// ---------------------------------------------------------------------------
// Template 2 — Modern
// ---------------------------------------------------------------------------

pw.Widget _modernPage(ReportCardData d) => pw.Container(
  color: _paper,
  padding: const pw.EdgeInsets.fromLTRB(34, 30, 34, 26),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(d.schoolName, style: _modernSchool),
                pw.Text(d.schoolMotto, style: _mutedText),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('REPORT CARD', style: _kicker),
              pw.Text(d.termLabel, style: _mutedText),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Container(height: 2, color: _navy),
      pw.SizedBox(height: 2),
      pw.Container(height: 0.8, color: _navyLight),
      pw.SizedBox(height: 16),
      pw.Text(d.studentName, style: _modernName),
      pw.SizedBox(height: 2),
      pw.Text('${d.classId} · ${d.admissionNo}', style: _mutedText),
      pw.SizedBox(height: 12),
      pw.Row(
        children: [
          _stat('Class', d.classId),
          _stat('Position', d.rankLabel),
          _stat('Attendance', d.attendance?.label ?? '-'),
        ],
      ),
      _title('Subjects'),
      for (final s in d.subjects) _modernSubjectRow(s),
      pw.SizedBox(height: 6),
      pw.Divider(thickness: 0.6, color: _hair),
      pw.SizedBox(height: 6),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('OVERALL', style: _statLabel),
                pw.SizedBox(height: 2),
                pw.Text("Class teacher's remark", style: _kvLabel),
              ],
            ),
          ),
          pw.Text(d.overallLabel, style: _score),
          pw.SizedBox(width: 6),
          pw.SizedBox(
            width: 18,
            child: pw.Text(
              d.overallGrade,
              textAlign: pw.TextAlign.right,
              style: _grade,
            ),
          ),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Text(d.remark, style: _body),
      pw.SizedBox(height: 4),
      pw.Text(
        d.teacherName.isEmpty
            ? 'Class teacher'
            : 'Class teacher · ${d.teacherName}',
        style: _mutedText,
      ),
      _footer(d),
    ],
  ),
);

/// One modern subject row: name, navy progress bar, average and grade.
pw.Widget _modernSubjectRow(SubjectResult s) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 3),
  child: pw.Row(
    children: [
      pw.Expanded(child: pw.Text(s.name, style: _subjectName)),
      _bar(s.average),
      pw.SizedBox(width: 8),
      pw.SizedBox(
        width: 46,
        child: pw.Text(
          s.averageLabel,
          textAlign: pw.TextAlign.right,
          style: _kvValue,
        ),
      ),
      pw.SizedBox(width: 6),
      pw.SizedBox(
        width: 18,
        child: pw.Text(s.grade, textAlign: pw.TextAlign.right, style: _grade),
      ),
    ],
  ),
);

/// Navy-only bar (one navy ramp — never traffic lights).
pw.Widget _bar(double? average) {
  final filled = average == null
      ? 0.0
      : average.clamp(0, 100).toDouble() / 100 * 92;
  return pw.Container(
    width: 92,
    height: 6,
    color: _navy100,
    child: pw.Align(
      alignment: pw.Alignment.centerLeft,
      child: pw.Container(width: filled, height: 6, color: _navy),
    ),
  );
}

// ---------------------------------------------------------------------------
// Template 3 — Ghanaian academic transcript
// ---------------------------------------------------------------------------

/// Subject names across every term on record, current term first.
List<String> transcriptSubjects(ReportCardData d) {
  final names = <String>[for (final s in d.subjects) s.name];
  for (final t in d.history) {
    for (final s in t.subjects) {
      if (!names.contains(s.name)) names.add(s.name);
    }
  }
  return names;
}

/// `78.5 (2)` for [name] in term [t], or `–`.
String transcriptCell(TermRecord t, String name) {
  final s = t.subjects.where((x) => x.name == name).firstOrNull;
  if (s == null || s.total == null) return '-';
  return '${s.totalLabel} (${s.termGrade})';
}

/// Mean total for [name] across every term with a result, or `null`.
double? transcriptMean(ReportCardData d, String name) {
  final totals = [
    for (final t in d.history)
      for (final s in t.subjects)
        if (s.name == name && s.total != null) s.total!,
  ];
  if (totals.isEmpty) return null;
  return totals.reduce((a, b) => a + b) / totals.length;
}

pw.Widget _transcriptPage(ReportCardData d) {
  final names = transcriptSubjects(d);
  final terms = d.history;
  final summary = pw.TextStyle(
    fontSize: 7.5,
    fontWeight: pw.FontWeight.bold,
    color: PdfColors.black,
  );
  return _ghFrame(
    pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        _ghHeader(d, 'ACADEMIC TRANSCRIPT'),
        _ghSectionTitle("STUDENT'S PARTICULARS"),
        _ghField('Name of student:', d.studentName, labelWidth: 76),
        _ghPair('Admission No.:', d.admissionNo, 'Gender:', d.gender),
        _ghPair(
          'Date of birth:',
          longDate(d.dateOfBirth),
          'Date of admission:',
          longDate(d.admissionDate),
        ),
        _ghPair('Current class:', d.classId, 'Status:', d.studentStatus),
        _ghSectionTitle('ACADEMIC RECORD'),
        pw.Table(
          border: _ghGrid,
          defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
          columnWidths: {
            0: const pw.FlexColumnWidth(3.2),
            for (var i = 0; i < terms.length; i++)
              i + 1: const pw.FlexColumnWidth(1.4),
            terms.length + 1: const pw.FlexColumnWidth(1.1),
            terms.length + 2: const pw.FlexColumnWidth(0.8),
            terms.length + 3: const pw.FlexColumnWidth(1.6),
          },
          children: [
            pw.TableRow(
              decoration: pw.BoxDecoration(color: _navy100),
              children: [
                _ghCell('SUBJECT', style: _ghTh, align: pw.TextAlign.left),
                for (final t in terms)
                  _ghCell(
                    t.termLabel.replaceAll(' · ', '\n').toUpperCase(),
                    style: _ghTh,
                  ),
                _ghCell('MEAN\nSCORE', style: _ghTh),
                _ghCell('GRADE', style: _ghTh),
                _ghCell('REMARKS', style: _ghTh),
              ],
            ),
            for (final name in names)
              () {
                final mean = transcriptMean(d, name);
                return pw.TableRow(
                  children: [
                    _ghCell(name, align: pw.TextAlign.left),
                    for (final t in terms) _ghCell(transcriptCell(t, name)),
                    _ghCell(
                      mean == null ? '-' : mean.toStringAsFixed(1),
                      style: _ghTdBold,
                    ),
                    _ghCell(
                      mean == null ? '-' : d.scheme.bandFor(mean).grade,
                      style: _ghTdBold,
                    ),
                    _ghCell(mean == null ? '-' : d.scheme.bandFor(mean).remark),
                  ],
                );
              }(),
            for (final row in [
              (
                'Term average',
                (TermRecord t) => t.overall == null
                    ? '-'
                    : '${t.overall!.toStringAsFixed(1)}%',
              ),
              (
                'Position in class',
                (TermRecord t) => t.rank == null || t.classSize == 0
                    ? '-'
                    : '${ordinal(t.rank!)} / ${t.classSize}',
              ),
              if (d.scheme.showAggregate)
                (
                  aggregateLabel(d.scheme),
                  (TermRecord t) => t.aggregate?.toString() ?? '-',
                ),
            ])
              pw.TableRow(
                decoration: pw.BoxDecoration(color: _navy50),
                children: [
                  _ghCell(row.$1, style: summary, align: pw.TextAlign.left),
                  for (final t in terms) _ghCell(row.$2(t), style: summary),
                  _ghCell(''),
                  _ghCell(''),
                  _ghCell(''),
                ],
              ),
          ],
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 3),
          child: pw.Text(
            'Each term shows the total out of 100 with its grade in brackets. '
            'Totals weight class score ${weightLabel(d.scheme.classWeight)} '
            'and examination ${weightLabel(d.scheme.examWeight)}'
            '${d.hasPartial ? '; * marks a term with only one of the two recorded' : ''}.',
            style: _ghSmall,
          ),
        ),
        _ghSectionTitle('CONDUCT AND REMARKS'),
        _ghField('General conduct:', '', labelWidth: 76),
        _ghField('Extra-curricular:', '', labelWidth: 76),
        _ghLines("Headteacher's remarks:", ''),
        pw.SizedBox(height: 10),
        _ghGradingKey(d.scheme),
        _ghSectionTitle('CERTIFICATION'),
        pw.Text(
          'This is to certify that the above is a true and accurate record of '
          'the academic performance of ${d.studentName} '
          '(Admission No. ${d.admissionNo.isEmpty ? '-' : d.admissionNo}) '
          'at ${d.schoolName}.',
          style: _body,
        ),
        pw.SizedBox(height: 26),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(child: _ghSignature("Headteacher's signature", '')),
            pw.SizedBox(width: 18),
            pw.Expanded(
              child: _ghSignature('Date issued', longDate(_iso(d.generatedAt))),
            ),
            pw.SizedBox(width: 18),
            _ghStamp(),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Text(
          "Not valid without the school's official stamp and the "
          "headteacher's signature.",
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 7,
            fontStyle: pw.FontStyle.italic,
            color: _ink,
          ),
        ),
        _footer(d),
      ],
    ),
  );
}
