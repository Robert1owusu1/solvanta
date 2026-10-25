import 'question.dart';

/// Where an OCR job sits in its life.
///
/// The states are deliberately strict about one thing: nothing moves to
/// [confirmed] except by a teacher pressing confirm. [read] is where output
/// waits for that judgement, and [reading] is never shown as a result — it is
/// the state in which there is no result yet.
enum OcrJobStatus {
  /// Parked on this device; the push happens on the next successful pull.
  queued('Queued offline'),

  /// A recogniser is running right now.
  reading('Reading'),

  /// Recognised, waiting for a teacher to check and correct it.
  read('Awaiting confirmation'),

  /// A teacher has accepted (and possibly corrected) the reading.
  confirmed('Confirmed by teacher'),

  /// Nothing usable came back. Kept rather than discarded so the reason is
  /// still on screen when the teacher retries.
  failed('Could not read');

  const OcrJobStatus(this.label);

  final String label;

  static OcrJobStatus fromKey(String key) => OcrJobStatus.values
      .firstWhere((s) => s.name == key, orElse: () => OcrJobStatus.queued);
}

/// One photo handed to the OCR pipeline, and everything that came back.
///
/// This is the local-first record: it is written to this device before any
/// network call, so a page photographed in a classroom with no signal still
/// exists and is still retried. The recognised text lives here until Phase 5
/// attaches it to the submission it was read from.
///
/// [reviewedText] is the teacher's version and [text] is the engine's. They
/// are separate fields on purpose — a correction must never overwrite what the
/// engine actually said, or the next person to look cannot tell the two apart.
class OcrJob {
  const OcrJob({
    required this.id,
    required this.subjectId,
    required this.topic,
    required this.type,
    required this.classId,
    required this.createdAt,
    this.requestId,
    this.imageBase64,
    this.contentType = 'image/jpeg',
    this.status = OcrJobStatus.queued,
    this.error = '',
    this.text = '',
    this.math = '',
    this.provider = '',
    this.costTier = '',
    this.lines = 0,
    this.confidence = 0,
    this.warnings = const [],
    this.reviewedText,
    this.confirmedAt,
  });

  /// Local identity, and the id given to the server-side generation request
  /// when one is created — derived from it so a retried create is recognised
  /// as the same request rather than becoming a second one.
  final String id;
  final String subjectId;
  final String topic;
  final QuestionType type;
  final String classId;
  final String createdAt;

  /// Server generation request id, once one exists.
  final String? requestId;

  /// The parked photo, base64. Held until the page has been read; a job that
  /// was read carries no bytes to retry.
  final String? imageBase64;
  final String contentType;

  final OcrJobStatus status;
  final String error;

  // What the recogniser produced.
  final String text;
  final String math;
  final String provider;
  final String costTier;
  final int lines;
  final double confidence;
  final List<String> warnings;

  // What the teacher decided.
  final String? reviewedText;
  final String? confirmedAt;

  /// What will actually be used downstream: the teacher's correction when
  /// there is one, otherwise the engine's reading.
  ///
  /// Never used as accepted output on its own — acceptance is [confirmedAt].
  String get effectiveText => reviewedText ?? text;

  bool get isConfirmed => confirmedAt != null;

  /// How far along this job is, used when merging two copies of it — the
  /// server's and this device's — back together.
  ///
  /// [OcrJobStatus.confirmed] ranks highest because it carries a teacher's
  /// decision: two copies where one is confirmed always resolve to the
  /// confirmed one, so a merge can never discard the only judgement in the
  /// whole pipeline. [failed] sits level with [reading] rather than above it —
  /// a page that could not be read must never beat one that was — and a job
  /// still waiting ranks lowest, so the server's finished copy wins wherever
  /// this device has not caught up yet.
  ///
  /// Ties keep the local copy, which is the one still carrying the photo: the
  /// server never receives the bytes.
  int get mergeRank => switch (status) {
        OcrJobStatus.confirmed => 3,
        OcrJobStatus.read => 2,
        OcrJobStatus.failed => 1,
        OcrJobStatus.reading => 1,
        OcrJobStatus.queued => 0,
      };

  OcrJob copyWith({
    String? requestId,
    String? imageBase64,
    OcrJobStatus? status,
    String? error,
    String? text,
    String? math,
    String? provider,
    String? costTier,
    int? lines,
    double? confidence,
    List<String>? warnings,
    String? reviewedText,
    String? confirmedAt,
    bool clearImage = false,
    bool clearError = false,
  }) =>
      OcrJob(
        id: id,
        subjectId: subjectId,
        topic: topic,
        type: type,
        classId: classId,
        createdAt: createdAt,
        requestId: requestId ?? this.requestId,
        imageBase64: clearImage ? null : (imageBase64 ?? this.imageBase64),
        contentType: contentType,
        status: status ?? this.status,
        error: clearError ? '' : (error ?? this.error),
        text: text ?? this.text,
        math: math ?? this.math,
        provider: provider ?? this.provider,
        costTier: costTier ?? this.costTier,
        lines: lines ?? this.lines,
        confidence: confidence ?? this.confidence,
        warnings: warnings ?? this.warnings,
        reviewedText: reviewedText ?? this.reviewedText,
        confirmedAt: confirmedAt ?? this.confirmedAt,
      );

  factory OcrJob.fromJson(Map<String, dynamic> json) => OcrJob(
        id: json['id'] as String,
        subjectId: (json['subjectId'] ?? '') as String,
        topic: (json['topic'] ?? '') as String,
        type: QuestionType.fromKey((json['type'] ?? 'shortAnswer') as String),
        classId: (json['classId'] ?? '') as String,
        createdAt: (json['createdAt'] ?? '') as String,
        requestId: json['requestId'] as String?,
        imageBase64: json['imageBase64'] as String?,
        contentType: (json['contentType'] ?? 'image/jpeg') as String,
        status: OcrJobStatus.fromKey((json['status'] ?? 'queued') as String),
        error: (json['error'] ?? '') as String,
        text: (json['text'] ?? '') as String,
        math: (json['math'] ?? '') as String,
        provider: (json['provider'] ?? '') as String,
        costTier: (json['costTier'] ?? '') as String,
        lines: (json['lines'] ?? 0) as int,
        confidence: ((json['confidence'] ?? 0) as num).toDouble(),
        warnings: ((json['warnings'] ?? const []) as List)
            .map((e) => e as String)
            .toList(),
        reviewedText: json['reviewedText'] as String?,
        confirmedAt: json['confirmedAt'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'subjectId': subjectId,
        'topic': topic,
        'type': type.name,
        'classId': classId,
        'createdAt': createdAt,
        'requestId': requestId,
        'imageBase64': imageBase64,
        'contentType': contentType,
        'status': status.name,
        'error': error,
        'text': text,
        'math': math,
        'provider': provider,
        'costTier': costTier,
        'lines': lines,
        'confidence': confidence,
        'warnings': warnings,
        'reviewedText': reviewedText,
        'confirmedAt': confirmedAt,
      };
}
