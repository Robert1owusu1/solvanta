import 'assignment.dart';

/// One teacher-captured page of a student's submitted assignment work.
///
/// Held inside an [AssignmentSubmission] rather than being a standalone
/// record, so a five-page answer booklet is ONE submission (doc §45–46) and
/// not five unrelated uploads that whoever marks has to reassemble by hand.
class AssignmentPage {
  const AssignmentPage({
    required this.id,
    required this.pageNumber,
    required this.imagePath,
    required this.capturedAt,
    this.qualityWarnings = const [],
  });

  /// Stable id. Also the key each page's photo is stored under on the server,
  /// so it must be unique across submissions.
  final String id;

  /// 1-based position within the booklet.
  final int pageNumber;

  /// Local path of the cropped photo, for preview on this device.
  final String imagePath;

  final String capturedAt;

  /// Advisory issues recorded at capture time. Blocking issues are NOT
  /// recorded — see [PageQualityVerdict.recordedWarnings] for why.
  final List<String> qualityWarnings;

  AssignmentPage copyWith({String? imagePath}) => AssignmentPage(
        id: id,
        pageNumber: pageNumber,
        imagePath: imagePath ?? this.imagePath,
        capturedAt: capturedAt,
        qualityWarnings: qualityWarnings,
      );

  factory AssignmentPage.fromJson(Map<String, dynamic> json) => AssignmentPage(
        id: json['id'] as String,
        pageNumber: (json['pageNumber'] ?? 1) as int,
        imagePath: (json['imagePath'] ?? '') as String,
        capturedAt: (json['capturedAt'] ?? '') as String,
        qualityWarnings:
            ((json['qualityWarnings'] ?? const []) as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'pageNumber': pageNumber,
        'imagePath': imagePath,
        'capturedAt': capturedAt,
        'qualityWarnings': qualityWarnings,
      };
}

enum AssignmentSubmissionStatus {
  queued('Queued'),
  needsReview('Needs review'),
  submitted('Submitted');

  const AssignmentSubmissionStatus(this.label);

  final String label;

  static AssignmentSubmissionStatus fromKey(String key) =>
      AssignmentSubmissionStatus.values.firstWhere(
        (s) => s.name == key,
        orElse: () => AssignmentSubmissionStatus.queued,
      );
}

/// A single submission of one student's work for one assignment, carrying any
/// number of photographed pages.
///
/// Offline-first like everything else here: the record and its pages are
/// written locally first, then mirrored to the API (and the photos parked if
/// the upload cannot go through yet).
class AssignmentSubmission {
  const AssignmentSubmission({
    required this.id,
    required this.assignmentId,
    required this.studentId,
    required this.classId,
    required this.subjectId,
    required this.recorder,
    required this.capturedAt,
    this.pages = const [],
    this.manualNotes = '',
    this.status = AssignmentSubmissionStatus.queued,
  });

  final String id;
  final String assignmentId;
  final String studentId;
  final String classId;
  final String subjectId;
  final String recorder;
  final String capturedAt;

  /// The photographed pages, in booklet order.
  final List<AssignmentPage> pages;

  /// Manual fallback entry (doc §47): the typed route used when there is no
  /// camera, no photo, or the photo route has failed. Deliberately a plain
  /// field rather than a separate record — a teacher who could not photograph
  /// the work still needs to hand over something, and it belongs to the same
  /// submission.
  final String manualNotes;

  final AssignmentSubmissionStatus status;

  bool get hasPhotos => pages.isNotEmpty;
  bool get hasManualEntry => manualNotes.trim().isNotEmpty;

  /// Every advisory warning across all pages, prefixed with the page number so
  /// a reviewer can tell which page was imperfect.
  List<String> get allWarnings => [
        for (final p in pages)
          for (final w in p.qualityWarnings) 'Page ${p.pageNumber}: $w'
      ];

  /// A copy with [page] inserted in booklet order.
  ///
  /// Page numbers are assigned here rather than by the capture screen, so the
  /// order cannot drift from the array and page 1 is always the first photo
  /// taken rather than whatever ended up first in a list.
  AssignmentSubmission withAppendedPage(AssignmentPage page) {
    final next = [...pages, page]
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    return copyWith(pages: next);
  }

  /// A copy without [pageId], renumbering the rest so the booklet stays
  /// contiguous. A gap in page numbers would read as a missing page.
  AssignmentSubmission withoutPage(String pageId) {
    final kept = pages.where((p) => p.id != pageId).toList()
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    return copyWith(pages: [
      for (var i = 0; i < kept.length; i++)
        AssignmentPage(
          id: kept[i].id,
          pageNumber: i + 1,
          imagePath: kept[i].imagePath,
          capturedAt: kept[i].capturedAt,
          qualityWarnings: kept[i].qualityWarnings,
        )
    ]);
  }

  AssignmentSubmission copyWith({
    List<AssignmentPage>? pages,
    String? manualNotes,
    AssignmentSubmissionStatus? status,
  }) =>
      AssignmentSubmission(
        id: id,
        assignmentId: assignmentId,
        studentId: studentId,
        classId: classId,
        subjectId: subjectId,
        recorder: recorder,
        capturedAt: capturedAt,
        pages: pages ?? this.pages,
        manualNotes: manualNotes ?? this.manualNotes,
        status: status ?? this.status,
      );

  factory AssignmentSubmission.fromJson(Map<String, dynamic> json) =>
      AssignmentSubmission(
        id: json['id'] as String,
        assignmentId: (json['assignmentId'] ?? '') as String,
        studentId: (json['studentId'] ?? '') as String,
        classId: (json['classId'] ?? '') as String,
        subjectId: (json['subjectId'] ?? '') as String,
        recorder: (json['recorder'] ?? '') as String,
        capturedAt: (json['capturedAt'] ?? '') as String,
        pages: ((json['pages'] ?? const []) as List)
            .map((e) => AssignmentPage.fromJson(e as Map<String, dynamic>))
            .toList(),
        manualNotes: (json['manualNotes'] ?? '') as String,
        status: AssignmentSubmissionStatus.fromKey(
            (json['status'] ?? '') as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assignmentId': assignmentId,
        'studentId': studentId,
        'classId': classId,
        'subjectId': subjectId,
        'recorder': recorder,
        'capturedAt': capturedAt,
        'pages': pages.map((p) => p.toJson()).toList(),
        'manualNotes': manualNotes,
        'status': status.name,
      };

  /// Builds a submission for [assignment], ready to receive pages.
  factory AssignmentSubmission.forAssignment({
    required Assignment assignment,
    required String studentId,
    required String recorder,
    required String capturedAt,
    required String id,
  }) =>
      AssignmentSubmission(
        id: id,
        assignmentId: assignment.id,
        studentId: studentId,
        classId: assignment.classId,
        subjectId: assignment.subjectId,
        recorder: recorder,
        capturedAt: capturedAt,
      );
}
