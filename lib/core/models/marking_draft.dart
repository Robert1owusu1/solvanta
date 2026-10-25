/// Draft marks from the matching engine (Phase 5), mirroring the API's
/// `MarkingDraft` JSON.
///
/// A draft is not a mark until a teacher finalizes it in the review screen
/// (Phase 6); only then is [MarkingDraft.isFinal] true. The engine's proposal
/// ([MarkingDraftAnswer.draftMarks]) is never overwritten — the teacher's
/// decision sits beside it in [MarkingDraftAnswer.finalMarks].
library;

List<String> _strings(Object? v) =>
    ((v ?? const []) as List).map((e) => e as String).toList();

double _num(Object? v) => ((v ?? 0) as num).toDouble();

/// One mark-breakdown step of a drafted question.
class DraftStep {
  const DraftStep({
    required this.stepId,
    required this.type,
    required this.criteria,
    required this.marks,
    required this.awarded,
    required this.status,
  });

  final String stepId;
  final String type;
  final String criteria;
  final double marks;
  final double awarded;

  /// awarded | not_awarded | needs_review | set_by_answer
  final String status;

  factory DraftStep.fromJson(Map<String, dynamic> json) => DraftStep(
        stepId: (json['stepId'] ?? '') as String,
        type: (json['type'] ?? '') as String,
        criteria: (json['criteria'] ?? '') as String,
        marks: _num(json['marks']),
        awarded: _num(json['awarded']),
        status: (json['status'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'stepId': stepId,
        'type': type,
        'criteria': criteria,
        'marks': marks,
        'awarded': awarded,
        'status': status,
      };
}

/// One question of a draft: what was read, the proposed mark, and why.
class MarkingDraftAnswer {
  const MarkingDraftAnswer({
    required this.schemeQuestionId,
    required this.questionNumber,
    required this.studentAnswer,
    required this.working,
    required this.draftMarks,
    required this.totalMarks,
    required this.method,
    required this.matchedText,
    required this.likelyCause,
    required this.needsReview,
    required this.reasons,
    required this.steps,
    this.finalMarks,
    this.teacherNote = '',
  });

  final String schemeQuestionId;
  final int questionNumber;
  final String studentAnswer;
  final List<String> working;
  final double draftMarks;
  final double totalMarks;

  /// exact | normalized | numeric | equivalent_form | unit_mismatch |
  /// rounded | misconception | none | blank
  final String method;
  final String matchedText;
  final String likelyCause;
  final bool needsReview;
  final List<String> reasons;
  final List<DraftStep> steps;

  /// The teacher's decision; null until the draft is finalized.
  final double? finalMarks;

  /// Why the teacher changed the proposed mark.
  final String teacherNote;

  /// Whether the teacher's mark differs from the proposal.
  bool get overridden => finalMarks != null && finalMarks != draftMarks;

  factory MarkingDraftAnswer.fromJson(Map<String, dynamic> json) =>
      MarkingDraftAnswer(
        schemeQuestionId: (json['schemeQuestionId'] ?? '') as String,
        questionNumber: (json['questionNumber'] ?? 0) as int,
        studentAnswer: (json['studentAnswer'] ?? '') as String,
        working: _strings(json['working']),
        draftMarks: _num(json['draftMarks']),
        totalMarks: _num(json['totalMarks']),
        method: (json['method'] ?? '') as String,
        matchedText: (json['matchedText'] ?? '') as String,
        likelyCause: (json['likelyCause'] ?? '') as String,
        needsReview: (json['needsReview'] ?? false) as bool,
        reasons: _strings(json['reasons']),
        steps: ((json['steps'] ?? const []) as List)
            .map((e) => DraftStep.fromJson(e as Map<String, dynamic>))
            .toList(),
        finalMarks: json['finalMarks'] == null ? null : _num(json['finalMarks']),
        teacherNote: (json['teacherNote'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'schemeQuestionId': schemeQuestionId,
        'questionNumber': questionNumber,
        'studentAnswer': studentAnswer,
        'working': working,
        'draftMarks': draftMarks,
        'totalMarks': totalMarks,
        'method': method,
        'matchedText': matchedText,
        'likelyCause': likelyCause,
        'needsReview': needsReview,
        'reasons': reasons,
        'steps': steps.map((s) => s.toJson()).toList(),
        'finalMarks': finalMarks,
        'teacherNote': teacherNote,
      };
}

/// The matching engine's proposal for one student's paper.
class MarkingDraft {
  const MarkingDraft({
    required this.id,
    required this.schemeId,
    required this.schemeVersion,
    required this.targetKind,
    required this.submissionId,
    required this.studentId,
    required this.classId,
    required this.sourceText,
    required this.ocrJobIds,
    required this.unassigned,
    required this.status,
    required this.draftTotal,
    required this.maxTotal,
    required this.needsReview,
    required this.createdAt,
    required this.answers,
    this.finalizedAt = '',
  });

  final String id;
  final String schemeId;
  final int schemeVersion;

  /// assessment | assignment
  final String targetKind;
  final String submissionId;
  final String studentId;
  final String classId;

  /// The teacher-confirmed text the draft was made from.
  final String sourceText;
  final List<String> ocrJobIds;

  /// Text that could not be attributed to any question; shown for review.
  final List<String> unassigned;

  /// draft | finalized | discarded
  final String status;
  final double draftTotal;
  final double maxTotal;

  /// How many questions are flagged for the teacher.
  final int needsReview;
  final String createdAt;
  final String finalizedAt;
  final List<MarkingDraftAnswer> answers;

  /// True only once a teacher has finalized it: then its marks are recorded.
  bool get isFinal => status == 'finalized';

  /// The recorded total once finalized.
  double get finalTotal =>
      answers.fold(0.0, (sum, a) => sum + (a.finalMarks ?? 0));

  factory MarkingDraft.fromJson(Map<String, dynamic> json) => MarkingDraft(
        id: json['id'] as String,
        schemeId: (json['schemeId'] ?? '') as String,
        schemeVersion: (json['schemeVersion'] ?? 0) as int,
        targetKind: (json['targetKind'] ?? '') as String,
        submissionId: (json['submissionId'] ?? '') as String,
        studentId: (json['studentId'] ?? '') as String,
        classId: (json['classId'] ?? '') as String,
        sourceText: (json['sourceText'] ?? '') as String,
        ocrJobIds: _strings(json['ocrJobIds']),
        unassigned: _strings(json['unassigned']),
        status: (json['status'] ?? 'draft') as String,
        draftTotal: _num(json['draftTotal']),
        maxTotal: _num(json['maxTotal']),
        needsReview: (json['needsReview'] ?? 0) as int,
        createdAt: (json['createdAt'] ?? '') as String,
        finalizedAt: (json['finalizedAt'] ?? '') as String,
        answers: ((json['answers'] ?? const []) as List)
            .map((e) => MarkingDraftAnswer.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'schemeId': schemeId,
        'schemeVersion': schemeVersion,
        'targetKind': targetKind,
        'submissionId': submissionId,
        'studentId': studentId,
        'classId': classId,
        'sourceText': sourceText,
        'ocrJobIds': ocrJobIds,
        'unassigned': unassigned,
        'status': status,
        'draftTotal': draftTotal,
        'maxTotal': maxTotal,
        'needsReview': needsReview,
        'createdAt': createdAt,
        'finalizedAt': finalizedAt,
        'answers': answers.map((a) => a.toJson()).toList(),
        'final': isFinal,
      };
}

/// A request for a draft, kept on the device until the server has answered.
///
/// Drafting needs the server (the scheme and the engine live there), so a
/// request made offline waits here and is sent on the next sync — the same
/// local-first shape as the OCR queue.
class MarkingDraftRequest {
  const MarkingDraftRequest({
    required this.id,
    required this.schemeId,
    required this.submissionId,
    required this.studentId,
    required this.ocrJobIds,
    required this.answers,
    required this.createdAt,
    this.error = '',
  });

  final String id;
  final String schemeId;
  final String submissionId;
  final String studentId;
  final List<String> ocrJobIds;

  /// Typed answers: {questionNumber, text, working}.
  final List<Map<String, dynamic>> answers;
  final String createdAt;

  /// Why the server refused it, when it did; empty while it is waiting.
  final String error;

  bool get failed => error.isNotEmpty;

  MarkingDraftRequest withError(String message) => MarkingDraftRequest(
        id: id,
        schemeId: schemeId,
        submissionId: submissionId,
        studentId: studentId,
        ocrJobIds: ocrJobIds,
        answers: answers,
        createdAt: createdAt,
        error: message,
      );

  Map<String, dynamic> body() => {
        'schemeId': schemeId,
        // Optional for an assessment: the server finds the student's paper.
        if (submissionId.isNotEmpty) 'submissionId': submissionId,
        'studentId': studentId,
        if (ocrJobIds.isNotEmpty) 'ocrJobIds': ocrJobIds,
        if (answers.isNotEmpty) 'answers': answers,
      };

  factory MarkingDraftRequest.fromJson(Map<String, dynamic> json) =>
      MarkingDraftRequest(
        id: json['id'] as String,
        schemeId: (json['schemeId'] ?? '') as String,
        submissionId: (json['submissionId'] ?? '') as String,
        studentId: (json['studentId'] ?? '') as String,
        ocrJobIds: _strings(json['ocrJobIds']),
        answers: ((json['answers'] ?? const []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        createdAt: (json['createdAt'] ?? '') as String,
        error: (json['error'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'schemeId': schemeId,
        'submissionId': submissionId,
        'studentId': studentId,
        'ocrJobIds': ocrJobIds,
        'answers': answers,
        'createdAt': createdAt,
        'error': error,
      };
}

/// A teacher's decision on one question in the review screen.
class DraftDecision {
  const DraftDecision({this.marks, this.note = '', this.checked = false});

  /// The mark the teacher will finalize; null until one is set.
  final double? marks;

  /// Why the mark differs from the proposal.
  final String note;

  /// The teacher has looked at a flagged question.
  final bool checked;

  DraftDecision copyWith({double? marks, bool clearMarks = false, String? note, bool? checked}) =>
      DraftDecision(
        marks: clearMarks ? null : (marks ?? this.marks),
        note: note ?? this.note,
        checked: checked ?? this.checked,
      );

  factory DraftDecision.fromJson(Map<String, dynamic> json) => DraftDecision(
        marks: json['marks'] == null ? null : _num(json['marks']),
        note: (json['note'] ?? '') as String,
        checked: (json['checked'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {'marks': marks, 'note': note, 'checked': checked};
}

/// Whether a review is ready to finalize, and if not, why. Every question
/// needs a mark within its total, and every flagged question must have been
/// ticked as checked or had its mark changed — nothing uncertain is accepted
/// unseen.
String? reviewBlocker(MarkingDraft draft, Map<String, DraftDecision> decisions) {
  for (final a in draft.answers) {
    final d = decisions[a.schemeQuestionId];
    final m = d?.marks;
    if (m == null) return 'Question ${a.questionNumber} has no mark yet.';
    if (m < 0 || m > a.totalMarks) {
      return 'Question ${a.questionNumber}: the mark must be between 0 and ${_fmt(a.totalMarks)}.';
    }
    if (a.needsReview && !(d!.checked || m != a.draftMarks)) {
      return 'Question ${a.questionNumber} was flagged — check it before finalizing.';
    }
  }
  return null;
}

/// "Accept all": fills in the proposed mark for every confidently matched
/// question that has no decision yet. Flagged questions are left alone.
Map<String, DraftDecision> acceptConfident(
    MarkingDraft draft, Map<String, DraftDecision> decisions) {
  final out = Map<String, DraftDecision>.from(decisions);
  for (final a in draft.answers) {
    if (a.needsReview) continue;
    final d = out[a.schemeQuestionId] ?? const DraftDecision();
    if (d.marks == null) out[a.schemeQuestionId] = d.copyWith(marks: a.draftMarks);
  }
  return out;
}

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceAll(RegExp(r'0$'), '');
