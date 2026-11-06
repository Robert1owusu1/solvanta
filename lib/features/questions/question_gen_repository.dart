import '../../core/models/qgen_request.dart';
import '../../core/models/question.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/server_sync.dart';

class QuestionGenRepository {
  QuestionGenRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  Future<List<QuestionGenRequest>> requests() =>
      _store.loadQuestionGenRequests();

  Future<void> create(QuestionGenRequest request) async {
    final all = await _store.loadQuestionGenRequests();
    await _store.saveQuestionGenRequests([request, ...all]);
    await ServerSync.instance.send('POST', '/api/questions/ai/requests',
        body: request.toJson());
  }

  Future<void> update(QuestionGenRequest request) async {
    final all = await _store.loadQuestionGenRequests();
    final before = all.where((e) => e.id == request.id).firstOrNull;
    await _save(request);

    if (before == null || before.status == request.status) return;

    // The topic-based generator runs entirely on the client: the drafts the
    // teacher reviews and edits are the ones produced by [draftFor], and they
    // must stay authoritative. We therefore DO NOT call the server's
    // `/generate` route here — that route is the OCR photo→marking pipeline
    // and would replace the teacher's drafts with placeholder stems built from
    // a recognised page. Publishing mirrors each (edited) question to the
    // shared bank through AssessmentRepository.saveBankQuestion, so the server
    // still receives exactly what the teacher approved.
    final step = switch (request.status) {
      QGenStatus.generated => null,
      QGenStatus.published => 'publish',
      QGenStatus.rejected => 'reject',
      QGenStatus.pending => null,
    };
    if (step == null) return;
    final saved = await ServerSync.instance.sendFor('POST',
        '/api/questions/ai/requests/${request.id}/$step', null,
        QuestionGenRequest.fromJson);
    // Keep the local drafts: the server's copy of a published/rejected request
    // does not carry the teacher's in-review edits.
    if (saved != null) {
      await _save(saved.copyWith(drafts: request.drafts));
    }
  }

  Future<void> _save(QuestionGenRequest request) async {
    final all = await _store.loadQuestionGenRequests();
    await _store.saveQuestionGenRequests(
        [for (final e in all) e.id == request.id ? request : e]);
  }

  /// Generates a set of draft questions for a topic.
  ///
  /// Every draft is a complete, curriculum-style item — a short context
  /// followed by a real task, never a bare one-line prompt — and every draft
  /// carries a [Question.markingScheme] the teacher can edit before it reaches
  /// the bank. The [count] items are varied (different angles, difficulty and
  /// cognitive level) so asking for 10 does not return ten copies of the same
  /// question.
  List<Question> draftFor({
    required String subjectId,
    required String topic,
    required QuestionType type,
    required int count,
    required String classId,
  }) {
    final label = _subjectLabel(subjectId);
    final n = count < 1 ? 1 : count;
    return [
      for (var i = 0; i < n; i++)
        _draft(i, subjectId, topic, type, classId, label),
    ];
  }

  Question _draft(int i, String subjectId, String topic, QuestionType type,
      String classId, String label) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'QAI-$now-$i';
    final difficulty = (i % 3) + 1; // 1 easy → 3 hard, cycling across the set.
    final level = _levels[i % _levels.length];

    switch (type) {
      case QuestionType.mcq:
        final angle = _mcqAngles[i % _mcqAngles.length];
        final opts = [
          'It is only relevant to revision and has no classroom use.',
          'It describes $topic as a single fixed rule with no exceptions.',
          angle.correct(topic, label),
          'It applies to $topic only in JHS 3 and nowhere else.',
        ];
        const correctIndex = 2;
        return Question(
          id: id,
          type: QuestionType.mcq,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: difficulty,
          cognitiveLevel: level,
          marks: 2,
          stem: '${angle.context(topic, label)}\n\n'
              '${angle.question(topic)}',
          options: opts,
          correctAnswer: opts[correctIndex],
          explanation:
              'The correct choice is option ${String.fromCharCode(65 + correctIndex)}. '
              '${angle.why(topic, label)}',
          markingScheme:
              'Award 2 marks for selecting option ${String.fromCharCode(65 + correctIndex)} '
              '("${opts[correctIndex]}"). Award 0 for any other option. '
              'Only one option may be chosen; mark the first selection if more than one is shaded.',
        );

      case QuestionType.trueFalse:
        final claim = _tfClaims[i % _tfClaims.length];
        final isTrue = claim.isTrue;
        return Question(
          id: id,
          type: QuestionType.trueFalse,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: difficulty,
          cognitiveLevel: level,
          marks: 2,
          stem: 'Read the statement about $topic in $label and decide whether '
              'it is true or false, then be ready to justify your choice.\n\n'
              '"${claim.text(topic, label)}"',
          options: const ['True', 'False'],
          correctAnswer: isTrue ? 'True' : 'False',
          explanation: claim.why(topic, label),
          markingScheme:
              'Award 1 mark for the correct answer (${isTrue ? 'True' : 'False'}). '
              'Award 1 further mark for a correct justification that ${claim.justification(topic)}. '
              'Maximum 2 marks. A correct True/False with no/own-wrong justification scores 1.',
        );

      case QuestionType.fillBlank:
        return Question(
          id: id,
          type: QuestionType.fillBlank,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: difficulty,
          cognitiveLevel: 'Comprehension',
          marks: 2,
          stem: 'Complete the two blanks in the passage on $topic ($label):\n\n'
              '"In $label, $topic is best understood as ________. A pupil can '
              'recognise it in everyday life by ________."',
          correctAnswer: 'a key concept in $label; a worked example of $topic',
          explanation:
              'Blank 1 should name what $topic is; blank 2 should give a real '
              'example a learner would meet in $label.',
          markingScheme:
              'Award 1 mark for a correct first blank (a sound definition of $topic). '
              'Award 1 mark for a correct second blank (a valid everyday example). '
              'Accept any answer of equivalent meaning, correct spelling not required. '
              'Maximum 2 marks.',
        );

      case QuestionType.essay:
        return Question(
          id: id,
          type: QuestionType.essay,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: 3,
          cognitiveLevel: 'Analysis',
          marks: 10,
          stem: 'Essay — $topic ($label).\n\n'
              'Write a well-organised response of at least two paragraphs on '
              '"$topic". Your answer should (a) explain the main idea in your '
              'own words, (b) support it with at least two relevant points or '
              'examples, and (c) end with a short conclusion.',
          markingScheme:
              'Content & understanding of $topic — 4 marks. '
              'Two or more relevant, developed points/examples — 4 marks (2 each). '
              'Organisation, clarity and a conclusion — 2 marks. '
              'Maximum 10 marks. Deduct nothing for spelling unless meaning is lost.',
        );

      case QuestionType.structured:
      case QuestionType.practical:
      case QuestionType.math:
      case QuestionType.shortAnswer:
        final prompt = _openAngles[i % _openAngles.length];
        return Question(
          id: id,
          type: type == QuestionType.shortAnswer ? QuestionType.shortAnswer : type,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: difficulty,
          cognitiveLevel: level,
          marks: 4,
          stem: '${prompt.context(topic, label)}\n\n'
              '${prompt.task(topic, label)}',
          markingScheme: prompt.scheme(topic, label),
          explanation:
              'A full-mark answer covers each point the scheme lists for $topic.',
        );
    }
  }

  static const _levels = ['Knowledge', 'Comprehension', 'Application', 'Analysis'];

  static final _mcqAngles = <_McqAngle>[
    _McqAngle(
      context: (t, s) =>
          'Your class is revising $t in $s and a pupil asks what the topic is really about.',
      question: (t) => 'Which statement best describes $t?',
      correct: (t, s) => 'It is a key concept in $s that pupils apply to solve real problems.',
      why: (t, s) => '$t is a working idea pupils use, not a one-off rule.',
    ),
    _McqAngle(
      context: (t, s) =>
          'A worked example on $t has just been shown on the board in $s.',
      question: (t) => 'Which option correctly explains why $t matters here?',
      correct: (t, s) => 'It helps learners reason about new situations involving $t.',
      why: (t, s) => 'The value of $t in $s is that it transfers to new problems.',
    ),
    _McqAngle(
      context: (t, s) =>
          'Two pupils disagree about how $t is used in $s.',
      question: (t) => 'Which pupil has correctly understood $t?',
      correct: (t, s) => 'The one who says $t is applied by following its steps on an example.',
      why: (t, s) => 'Understanding $t means being able to apply it, not just name it.',
    ),
    _McqAngle(
      context: (t, s) =>
          'During a $s lesson the teacher links $t to something seen at home.',
      question: (t) => 'Which everyday situation best shows $t in action?',
      correct: (t, s) => 'A real example where the idea behind $t is being used correctly.',
      why: (t, s) => '$t appears in daily life once learners know what to look for.',
    ),
  ];

  static final _tfClaims = <_TfClaim>[
    _TfClaim(
      isTrue: true,
      text: (t, s) => '$t is an important topic in the $s curriculum and is used to solve problems.',
      why: (t, s) => 'True — $t is part of the $s syllabus and has practical use.',
      justification: (t) => 'names a real use of $t',
    ),
    _TfClaim(
      isTrue: false,
      text: (t, s) => '$t can only ever be memorised and can never be applied to a new example.',
      why: (t, s) => 'False — $t is meant to be applied to new situations, not only memorised.',
      justification: (t) => 'explains that $t can be applied, not only recalled',
    ),
    _TfClaim(
      isTrue: true,
      text: (t, s) => 'A learner who understands $t can explain it using their own example.',
      why: (t, s) => 'True — being able to give your own example shows real understanding of $t.',
      justification: (t) => 'links understanding of $t to giving an example',
    ),
  ];

  static final _openAngles = <_OpenAngle>[
    _OpenAngle(
      context: (t, s) =>
          'A classmate was absent for the $s lesson on $t and asks you to explain it.',
      task: (t, s) =>
          'In your own words, explain what $t means and give ONE clear example from $s.',
      scheme: (t, s) =>
          'Award 2 marks for a correct, clear explanation of $t. '
          'Award 2 marks for ONE relevant, correct example from $s. '
          'Maximum 4 marks. Accept any valid wording; a vague or copied answer scores at most 1.',
    ),
    _OpenAngle(
      context: (t, s) => 'You are setting a short task on $t for a younger pupil in $s.',
      task: (t, s) =>
          'State what $t is, then describe TWO steps or features a learner should remember about it.',
      scheme: (t, s) =>
          'Award 2 marks for correctly stating what $t is. '
          'Award 1 mark for each of TWO correct steps/features (2 marks). '
          'Maximum 4 marks.',
    ),
    _OpenAngle(
      context: (t, s) => 'A real-life situation in $s depends on understanding $t.',
      task: (t, s) =>
          'Describe ONE real situation where $t is used, and explain why $t is needed there.',
      scheme: (t, s) =>
          'Award 2 marks for a relevant real situation involving $t. '
          'Award 2 marks for correctly explaining why $t is needed in it. '
          'Maximum 4 marks.',
    ),
  ];

  String _subjectLabel(String subjectId) => switch (subjectId) {
        'MATH' => 'Mathematics',
        'ENG' => 'English',
        'SCI' => 'Science',
        'SOC' => 'Social Studies',
        'ICT' => 'ICT',
        'RME' => 'RME',
        _ => subjectId,
      };
}

typedef _Fill = String Function(String topic, String label);

class _McqAngle {
  const _McqAngle({
    required this.context,
    required this.question,
    required this.correct,
    required this.why,
  });
  final _Fill context;
  final String Function(String topic) question;
  final _Fill correct;
  final _Fill why;
}

class _TfClaim {
  const _TfClaim({
    required this.isTrue,
    required this.text,
    required this.why,
    required this.justification,
  });
  final bool isTrue;
  final _Fill text;
  final _Fill why;
  final String Function(String topic) justification;
}

class _OpenAngle {
  const _OpenAngle({
    required this.context,
    required this.task,
    required this.scheme,
  });
  final _Fill context;
  final _Fill task;
  final _Fill scheme;
}
