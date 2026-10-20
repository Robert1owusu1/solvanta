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

    // The API moves a request on through explicit steps; send the one this
    // update made. Generation happens there too, so keep its drafts (they
    // are what publishing puts in the shared bank).
    if (before == null || before.status == request.status) return;
    final step = switch (request.status) {
      QGenStatus.generated => 'generate',
      QGenStatus.published => 'publish',
      QGenStatus.rejected => 'reject',
      QGenStatus.pending => null,
    };
    if (step == null) return;
    final saved = await ServerSync.instance.sendFor('POST',
        '/api/questions/ai/requests/${request.id}/$step', null,
        QuestionGenRequest.fromJson);
    if (saved != null) await _save(saved);
  }

  Future<void> _save(QuestionGenRequest request) async {
    final all = await _store.loadQuestionGenRequests();
    await _store.saveQuestionGenRequests(
        [for (final e in all) e.id == request.id ? request : e]);
  }

  /// Simulated AI generation: drafts are produced locally from templates so
  /// the pump-line (generate → review → publish) can run on-device. A real
  /// engine would be called here via the same [QuestionGenRequest] contract.
  List<Question> draftFor({
    required String subjectId,
    required String topic,
    required QuestionType type,
    required int count,
    required String classId,
  }) {
    final label = _subjectLabel(subjectId);
    return [
      for (var i = 0; i < count; i++)
        _draft(i, subjectId, topic, type, classId, label),
    ];
  }

  Question _draft(int i, String subjectId, String topic, QuestionType type,
      String classId, String label) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'QAI-$now-$i';
    switch (type) {
      case QuestionType.mcq:
        final stems = [
          'Which of the following best describes $topic?',
          'In the topic "$topic", which statement is correct?',
          'Choose the statement that is true about $topic.',
          'Which option correctly applies to $topic?',
        ];
        final opts = [
          '$topic is always a visual aid',
          '$topic is taught only in JHS 3',
          '$topic is a key concept in $label',
          '$topic requires practice and careful review',
        ];
        return Question(
          id: id,
          type: QuestionType.mcq,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: (i % 3) + 1,
          cognitiveLevel: i % 2 == 0 ? 'Knowledge' : 'Application',
          marks: 2,
          stem: stems[i % stems.length],
          options: opts,
          correctAnswer: opts[2],
          explanation: 'In $label, $topic is a core concept; the correct '
              'statement is the third option.',
        );
      case QuestionType.trueFalse:
        return Question(
          id: id,
          type: QuestionType.trueFalse,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: 1,
          cognitiveLevel: 'Knowledge',
          marks: 1,
          stem: i % 3 == 0
              ? 'In $label, the topic $topic is not part of the curriculum.'
              : '$topic is an important topic covered in $label.',
          options: const ['True', 'False'],
          correctAnswer: i % 3 == 0 ? 'False' : 'True',
          explanation:
              'True or False checks your recall of whether $topic belongs '
              'to the $label curriculum.',
        );
      case QuestionType.fillBlank:
        return Question(
          id: id,
          type: QuestionType.fillBlank,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: 2,
          cognitiveLevel: 'Comprehension',
          marks: 2,
          stem: 'In $label, the study of $topic is central to the term. '
              'Complete: ___ .',
          correctAnswer: topic,
          explanation: 'The key term for this section is "$topic".',
        );
      default:
        return Question(
          id: id,
          type: QuestionType.shortAnswer,
          subjectId: subjectId,
          classId: classId,
          topic: topic,
          difficulty: 2,
          cognitiveLevel: 'Application',
          marks: 4,
          stem: 'Explain in your own words what $topic means, and give one '
              'example from $label.',
          markingScheme:
              'Any accurate description of $topic with a clear example '
              'scores full marks (4).',
        );
    }
  }

  String _subjectLabel(String subjectId) =>
      switch (subjectId) {
        'MATH' => 'Mathematics',
        'ENG' => 'English',
        'SCI' => 'Science',
        'SOC' => 'Social Studies',
        'ICT' => 'ICT',
        'RME' => 'RME',
        _ => subjectId,
      };
}