/// One student's report for one term (mirrors the server's `term_reports`
/// records): the class teacher's remark and assessment of the pupil, the
/// headteacher's remark, and — once approved — the frozen card.
///
/// The server decides who may write what: the class teacher their own
/// class's drafts, school leaders the headteacher's remark, approval and
/// reopening. Families only ever receive approved reports.
class TermReport {
  final String studentId;
  final String classId;
  final String year;
  final String term;
  final String teacherRemark;
  final String conduct;
  final String attitude;
  final String interest;
  final String headRemark;
  final bool approved;
  final String approvedBy;
  final String approvedAt;

  /// The card exactly as approved (`ReportCardData.toJson`), or `null`.
  final Map<String, dynamic>? snapshot;

  const TermReport({
    required this.studentId,
    required this.classId,
    required this.year,
    required this.term,
    this.teacherRemark = '',
    this.conduct = '',
    this.attitude = '',
    this.interest = '',
    this.headRemark = '',
    this.approved = false,
    this.approvedBy = '',
    this.approvedAt = '',
    this.snapshot,
  });

  /// `2026-2027-Term-1-STU-001` — one per student per term, URL-safe.
  static String idFor(String year, String term, String studentId) =>
      '${year.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}-'
      '${term.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-')}-$studentId';

  String get id => idFor(year, term, studentId);

  /// The usual words for conduct, attitude and interest on a Ghanaian card.
  static const ratings = [
    'Excellent',
    'Very good',
    'Good',
    'Satisfactory',
    'Needs improvement',
  ];

  factory TermReport.fromJson(Map<String, dynamic> j) => TermReport(
        studentId: (j['studentId'] ?? '') as String,
        classId: (j['classId'] ?? '') as String,
        year: (j['year'] ?? '') as String,
        term: (j['term'] ?? '') as String,
        teacherRemark: (j['teacherRemark'] ?? '') as String,
        conduct: (j['conduct'] ?? '') as String,
        attitude: (j['attitude'] ?? '') as String,
        interest: (j['interest'] ?? '') as String,
        headRemark: (j['headRemark'] ?? '') as String,
        approved: j['status'] == 'approved',
        approvedBy: (j['approvedBy'] ?? '') as String,
        approvedAt: (j['approvedAt'] ?? '') as String,
        snapshot: j['snapshot'] is Map<String, dynamic>
            ? j['snapshot'] as Map<String, dynamic>
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'studentId': studentId,
        'classId': classId,
        'year': year,
        'term': term,
        'teacherRemark': teacherRemark,
        'conduct': conduct,
        'attitude': attitude,
        'interest': interest,
        'headRemark': headRemark,
        'status': approved ? 'approved' : 'draft',
        if (approvedBy.isNotEmpty) 'approvedBy': approvedBy,
        if (approvedAt.isNotEmpty) 'approvedAt': approvedAt,
        'snapshot': ?snapshot,
      };

  TermReport copyWith({
    String? teacherRemark,
    String? conduct,
    String? attitude,
    String? interest,
    String? headRemark,
  }) =>
      TermReport(
        studentId: studentId,
        classId: classId,
        year: year,
        term: term,
        teacherRemark: teacherRemark ?? this.teacherRemark,
        conduct: conduct ?? this.conduct,
        attitude: attitude ?? this.attitude,
        interest: interest ?? this.interest,
        headRemark: headRemark ?? this.headRemark,
        approved: approved,
        approvedBy: approvedBy,
        approvedAt: approvedAt,
        snapshot: snapshot,
      );

  /// This report approved with [card] frozen in it (the server stamps who
  /// and when), or reopened as a draft when [card] is `null`.
  TermReport withApproval(Map<String, dynamic>? card) => TermReport(
        studentId: studentId,
        classId: classId,
        year: year,
        term: term,
        teacherRemark: teacherRemark,
        conduct: conduct,
        attitude: attitude,
        interest: interest,
        headRemark: headRemark,
        approved: card != null,
        snapshot: card,
      );
}
