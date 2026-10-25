/// Marking scheme models for AI-assisted grading.
///
/// A [MarkingScheme] is a structured template that defines how a teacher
/// should grade an assessment or assignment. It contains questions,
/// accepted answer variants with normalized forms for fuzzy matching,
/// partial-credit mark breakdowns, and common misconceptions.
///
/// The scheme is versioned: when edited after submissions exist,
/// a new version is created so already-reviewed grades are never
/// silently re-graded.
library;

class MarkingScheme {
  final String id;
  final String? assessmentId;
  final String? assignmentId;
  final int version;
  final String? parentSchemeId;
  final String createdBy;
  final String createdAt;
  final List<SchemeQuestion> questions;

  const MarkingScheme({
    required this.id,
    this.assessmentId,
    this.assignmentId,
    required this.version,
    this.parentSchemeId,
    required this.createdBy,
    required this.createdAt,
    this.questions = const [],
  });

  factory MarkingScheme.fromJson(Map<String, dynamic> json) => MarkingScheme(
        id: json['id'] as String,
        assessmentId: json['assessmentId'] as String?,
        assignmentId: json['assignmentId'] as String?,
        version: (json['version'] as num?)?.toInt() ?? 1,
        parentSchemeId: json['parentSchemeId'] as String?,
        createdBy: json['createdBy'] as String,
        createdAt: json['createdAt'] as String,
        questions: ((json['questions'] ?? const []) as List)
            .map((e) => SchemeQuestion.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (assessmentId != null) 'assessmentId': assessmentId,
        if (assignmentId != null) 'assignmentId': assignmentId,
        'version': version,
        if (parentSchemeId != null) 'parentSchemeId': parentSchemeId,
        'createdBy': createdBy,
        'createdAt': createdAt,
        'questions': questions.map((e) => e.toJson()).toList(),
      };
}

/// One question within a marking scheme.
class SchemeQuestion {
  final String id;
  final String schemeId;
  final int questionNumber;
  final double totalMarks;
  final List<MarkBreakdownStep> markBreakdown;
  final List<AcceptedAnswer> acceptedAnswers;
  final List<Misconception> misconceptions;
  final String createdAt;

  const SchemeQuestion({
    required this.id,
    required this.schemeId,
    required this.questionNumber,
    required this.totalMarks,
    this.markBreakdown = const [],
    this.acceptedAnswers = const [],
    this.misconceptions = const [],
    required this.createdAt,
  });

  factory SchemeQuestion.fromJson(Map<String, dynamic> json) => SchemeQuestion(
        id: json['id'] as String,
        schemeId: json['schemeId'] as String,
        questionNumber: (json['questionNumber'] as num?)?.toInt() ?? 1,
        totalMarks: ((json['totalMarks'] ?? 0) as num).toDouble(),
        markBreakdown: ((json['markBreakdown'] ?? const []) as List)
            .map((e) => MarkBreakdownStep.fromJson(e as Map<String, dynamic>))
            .toList(),
        acceptedAnswers: ((json['acceptedAnswers'] ?? const []) as List)
            .map((e) => AcceptedAnswer.fromJson(e as Map<String, dynamic>))
            .toList(),
        misconceptions: ((json['misconceptions'] ?? const []) as List)
            .map((e) => Misconception.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: json['createdAt'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'schemeId': schemeId,
        'questionNumber': questionNumber,
        'totalMarks': totalMarks,
        'markBreakdown': markBreakdown.map((e) => e.toJson()).toList(),
        'acceptedAnswers': acceptedAnswers.map((e) => e.toJson()).toList(),
        'misconceptions': misconceptions.map((e) => e.toJson()).toList(),
        'createdAt': createdAt,
      };
}

/// One partial-credit step in a question's mark breakdown.
class MarkBreakdownStep {
  final String id;
  final String type; // "method" | "final_answer" | "working" | "other"
  final String criteria;
  final double marks;

  const MarkBreakdownStep({
    required this.id,
    required this.type,
    required this.criteria,
    required this.marks,
  });

  factory MarkBreakdownStep.fromJson(Map<String, dynamic> json) => MarkBreakdownStep(
        id: json['id'] as String,
        type: json['type'] as String,
        criteria: json['criteria'] as String,
        marks: ((json['marks'] ?? 0) as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'criteria': criteria,
        'marks': marks,
      };
}

/// One valid answer variant for a scheme question.
class AcceptedAnswer {
  final int id;
  final String schemeQuestionId;
  final String answerText;
  final String normalizedForm;
  final double marksAwarded;
  final bool isPrimary;
  final String createdAt;

  const AcceptedAnswer({
    required this.id,
    required this.schemeQuestionId,
    required this.answerText,
    required this.normalizedForm,
    required this.marksAwarded,
    required this.isPrimary,
    required this.createdAt,
  });

  factory AcceptedAnswer.fromJson(Map<String, dynamic> json) => AcceptedAnswer(
        id: (json['id'] as num).toInt(),
        schemeQuestionId: json['schemeQuestionId'] as String,
        answerText: json['answerText'] as String,
        normalizedForm: json['normalizedForm'] as String,
        marksAwarded: ((json['marksAwarded'] ?? 0) as num).toDouble(),
        isPrimary: json['isPrimary'] as bool? ?? false,
        createdAt: json['createdAt'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'schemeQuestionId': schemeQuestionId,
        'answerText': answerText,
        'normalizedForm': normalizedForm,
        'marksAwarded': marksAwarded,
        'isPrimary': isPrimary,
        'createdAt': createdAt,
      };
}

/// A common wrong-answer pattern with likely cause.
class Misconception {
  final int id;
  final String schemeQuestionId;
  final String wrongAnswerPattern;
  final String likelyCause;
  final double marksAwarded;
  final String createdAt;

  const Misconception({
    required this.id,
    required this.schemeQuestionId,
    required this.wrongAnswerPattern,
    required this.likelyCause,
    required this.marksAwarded,
    required this.createdAt,
  });

  factory Misconception.fromJson(Map<String, dynamic> json) => Misconception(
        id: (json['id'] as num).toInt(),
        schemeQuestionId: json['schemeQuestionId'] as String,
        wrongAnswerPattern: json['wrongAnswerPattern'] as String,
        likelyCause: json['likelyCause'] as String,
        marksAwarded: ((json['marksAwarded'] ?? 0) as num).toDouble(),
        createdAt: json['createdAt'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'schemeQuestionId': schemeQuestionId,
        'wrongAnswerPattern': wrongAnswerPattern,
        'likelyCause': likelyCause,
        'marksAwarded': marksAwarded,
        'createdAt': createdAt,
      };
}

/// A photographed page of a student's assignment, linked to a submission.
class ScanPage {
  final String id;
  final String submissionId;
  final String? schemeId;
  final int pageNumber;
  final String? imageId;
  final String? ocrText;
  final double? ocrConfidence;
  final String ocrStatus; // pending|processing|ready|needs_review|failed
  final String? ocrMetadata;
  final String createdAt;

  const ScanPage({
    required this.id,
    required this.submissionId,
    this.schemeId,
    required this.pageNumber,
    this.imageId,
    this.ocrText,
    this.ocrConfidence,
    required this.ocrStatus,
    this.ocrMetadata,
    required this.createdAt,
  });

  factory ScanPage.fromJson(Map<String, dynamic> json) => ScanPage(
        id: json['id'] as String,
        submissionId: json['submissionId'] as String,
        schemeId: json['schemeId'] as String?,
        pageNumber: (json['pageNumber'] as num?)?.toInt() ?? 1,
        imageId: json['imageId'] as String?,
        ocrText: json['ocrText'] as String?,
        ocrConfidence: json['ocrConfidence'] != null
            ? (json['ocrConfidence'] as num).toDouble()
            : null,
        ocrStatus: json['ocrStatus'] as String? ?? 'pending',
        ocrMetadata: json['ocrMetadata'] as String?,
        createdAt: json['createdAt'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'submissionId': submissionId,
        if (schemeId != null) 'schemeId': schemeId,
        'pageNumber': pageNumber,
        if (imageId != null) 'imageId': imageId,
        if (ocrText != null) 'ocrText': ocrText,
        if (ocrConfidence != null) 'ocrConfidence': ocrConfidence,
        'ocrStatus': ocrStatus,
        if (ocrMetadata != null) 'ocrMetadata': ocrMetadata,
        'createdAt': createdAt,
      };
}