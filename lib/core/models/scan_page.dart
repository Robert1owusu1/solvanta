/// A captured photo of a student's answer sheet, awaiting processing.
///
/// Represents the paper-first capture stage (doc §45–46): the teacher
/// photographs the page, the app runs quick quality checks, and the page is
/// queued for OCR / AI answer extraction on the backend. Until a backend
/// exists the teacher can still open the regular marking flow.
enum ScanStatus {
  queued('Queued'),
  needsReview('Needs review'),
  processed('Processed');

  const ScanStatus(this.label);

  final String label;

  static ScanStatus fromKey(String key) => ScanStatus.values
      .firstWhere((s) => s.name == key, orElse: () => ScanStatus.queued);
}

class ScanPage {
  final String id;
  final String assessmentId;
  final String studentId;
  final String imagePath;
  final int pageNumber;
  final String capturedAt;
  final String recorder;
  final ScanStatus status;
  final List<String> qualityWarnings;

  const ScanPage({
    required this.id,
    required this.assessmentId,
    required this.studentId,
    required this.imagePath,
    required this.pageNumber,
    required this.capturedAt,
    required this.recorder,
    required this.status,
    this.qualityWarnings = const [],
  });

  ScanPage copyWith({
    ScanStatus? status,
    List<String>? qualityWarnings,
  }) =>
      ScanPage(
        id: id,
        assessmentId: assessmentId,
        studentId: studentId,
        imagePath: imagePath,
        pageNumber: pageNumber,
        capturedAt: capturedAt,
        recorder: recorder,
        status: status ?? this.status,
        qualityWarnings: qualityWarnings ?? this.qualityWarnings,
      );

  factory ScanPage.fromJson(Map<String, dynamic> json) => ScanPage(
        id: json['id'] as String,
        assessmentId: json['assessmentId'] as String,
        studentId: json['studentId'] as String,
        imagePath: (json['imagePath'] ?? '') as String,
        pageNumber: (json['pageNumber'] ?? 1) as int,
        capturedAt: (json['capturedAt'] ?? '') as String,
        recorder: (json['recorder'] ?? '') as String,
        status: ScanStatus.fromKey(json['status'] as String),
        qualityWarnings:
            ((json['qualityWarnings'] ?? const []) as List).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assessmentId': assessmentId,
        'studentId': studentId,
        'imagePath': imagePath,
        'pageNumber': pageNumber,
        'capturedAt': capturedAt,
        'recorder': recorder,
        'status': status.name,
        'qualityWarnings': qualityWarnings,
      };
}