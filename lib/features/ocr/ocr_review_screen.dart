import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/ocr_job.dart';
import '../../core/models/question.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import 'ocr_repository.dart';

/// Lists a teacher's OCR pages and lets a new one be queued.
///
/// The subject is asked for up front rather than guessed, because it is what
/// routes the page: Maths goes to the math-notation engine and everything else
/// to plain handwriting. Photographing a page without saying what it is would
/// mean guessing the engine for a student's answer.
class OcrReviewScreen extends StatefulWidget {
  const OcrReviewScreen({super.key});

  @override
  State<OcrReviewScreen> createState() => _OcrReviewScreenState();
}

class _OcrReviewScreenState extends State<OcrReviewScreen> {
  final _repo = OcrRepository();
  final _picker = ImagePicker();
  final _topic = TextEditingController();

  String _subjectId = subjects.first.id;
  List<OcrJob> _jobs = const [];
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final jobs = await _repo.all();
    if (!mounted) return;
    setState(() => _jobs = jobs);
  }

  Future<void> _recognise() async {
    final topic = _topic.text.trim();
    if (topic.isEmpty) {
      _snack('Say what topic this page covers before photographing it.',
          AppColors.warning);
      return;
    }
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2200,
      imageQuality: 92,
    );
    if (file == null) return;

    setState(() => _working = true);
    try {
      final bytes = await file.readAsBytes();
      final job = OcrJob(
        id: 'OCR-${DateTime.now().microsecondsSinceEpoch}',
        subjectId: _subjectId,
        topic: topic,
        type: QuestionType.shortAnswer,
        classId: '',
        createdAt: DateTime.now().toIso8601String(),
        imageBase64: base64Encode(bytes),
      );
      // Local write first — the job exists on this device before any network
      // call, so losing signal part-way through costs nothing.
      await _repo.enqueue(job);
      _topic.clear();
      await _load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => OcrConfirmationScreen(job: job)),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _retry(OcrJob job) async {
    setState(() => _working = true);
    try {
      await _repo.push(job);
      await _load();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _snack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _jobs.where((j) => j.status == OcrJobStatus.queued).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Read photographed work')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _newPageCard(),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text('Queued & read pages',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (pending > 0)
                Text('$pending waiting for connection',
                    style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 8),
          if (_jobs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Nothing queued yet. Photograph a page and it will be read, '
                'then checked by you before anything is marked from it.',
                // AppColors.muted is a getter, so this cannot be const.
                style: TextStyle(color: AppColors.muted),
              ),
            ),
          for (final job in _jobs) _jobTile(job),
        ],
      ),
    );
  }

  Widget _newPageCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Recognise a new page',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'Subject decides which engine reads it — Mathematics uses the '
              'math-notation reader, everything else reads plain handwriting.',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            // isExpanded is load-bearing here, not cosmetic: a closed dropdown
            // sizes itself to the widest item it holds, and "Information &
            // Communication Technology" is wider than a phone. Without it the
            // field overflows the card instead of clipping its own label.
            DropdownButtonFormField<String>(
              initialValue: _subjectId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Subject'),
              items: [
                for (final s in subjects)
                  DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _subjectId = v ?? _subjectId),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _topic,
              decoration: const InputDecoration(
                labelText: 'Topic',
                hintText: 'e.g. Linear equations',
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _working ? null : _recognise,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_working ? 'Working…' : 'Choose a photo'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobTile(OcrJob job) {
    final (icon, color, label) = switch (job.status) {
      OcrJobStatus.queued => (Icons.cloud_off, AppColors.warning, 'Queued'),
      OcrJobStatus.reading => (Icons.autorenew, AppColors.info, 'Reading'),
      OcrJobStatus.read =>
        (Icons.rule, AppColors.warning, 'Waiting for you'),
      OcrJobStatus.confirmed =>
        (Icons.check_circle, AppColors.success, 'Confirmed'),
      OcrJobStatus.failed => (Icons.error, AppColors.danger, 'Could not read'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(job.topic),
        subtitle: Text(
          [
            subjectName(job.subjectId),
            label,
            if (job.confirmedAt != null) 'confirmed',
          ].join(' · '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: job.status == OcrJobStatus.queued
            ? IconButton(
                tooltip: 'Try now',
                icon: const Icon(Icons.refresh),
                onPressed: _working ? null : () => _retry(job),
              )
            : const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => OcrConfirmationScreen(job: job)));
          await _load();
        },
      ),
    );
  }
}

/// The confirmation step: what the engine read, and a teacher's decision
/// about it.
///
/// Nothing here is treated as accepted output until confirm is pressed. The
/// engine's text is shown separately from the editable one and is never
/// overwritten by an edit — a correction has to sit beside what was actually
/// read, or nobody afterwards can tell the two apart.
class OcrConfirmationScreen extends StatefulWidget {
  const OcrConfirmationScreen({super.key, required this.job});

  final OcrJob job;

  @override
  State<OcrConfirmationScreen> createState() => _OcrConfirmationScreenState();
}

class _OcrConfirmationScreenState extends State<OcrConfirmationScreen> {
  final _repo = OcrRepository();
  late final TextEditingController _review;
  late OcrJob _job;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _job = widget.job;
    _review = TextEditingController(text: _job.reviewedText ?? _job.text);
  }

  @override
  void dispose() {
    _review.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() => _working = true);
    try {
      await _repo.confirm(_job.id, _review.text);
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _retry() async {
    setState(() => _working = true);
    try {
      await _repo.push(_job);
      final jobs = await _repo.all();
      if (!mounted) return;
      final fresh = jobs.where((j) => j.id == _job.id).firstOrNull;
      if (fresh != null) {
        setState(() {
          _job = fresh;
          if (fresh.status == OcrJobStatus.read) {
            _review.text = fresh.reviewedText ?? fresh.text;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_job.topic)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            subjectName(_job.subjectId),
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          ..._photo(),
          ..._statusNotice(),
          if (_job.status == OcrJobStatus.read ||
              _job.status == OcrJobStatus.confirmed) ...[
            _engineCard(),
            const SizedBox(height: 14),
            _reviewField(),
          ],
          const SizedBox(height: 16),
          if (_job.status == OcrJobStatus.read) _confirmButton(),
          if (_job.status == OcrJobStatus.confirmed) _confirmedNote(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _photo() {
    final raw = _job.imageBase64;
    if (raw == null || raw.isEmpty) return const [];
    return [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          base64Decode(raw),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
      Text(
        'Check the reading below against this photo.',
        style: TextStyle(fontSize: 11, color: AppColors.muted),
      ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _statusNotice() {
    switch (_job.status) {
      case OcrJobStatus.queued:
        return [
          _notice(
            Icons.cloud_off,
            AppColors.warning,
            'Queued — this page has not been read yet.',
            _job.error.isEmpty
                ? 'It will be read automatically once this device is back '
                    'online, or you can try now.'
                : _job.error,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _working ? null : _retry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try now'),
          ),
          const SizedBox(height: 12),
        ];
      case OcrJobStatus.reading:
        return [
          _notice(Icons.autorenew, AppColors.info, 'Reading the page…', ''),
          const SizedBox(height: 12),
        ];
      case OcrJobStatus.failed:
        return [
          _notice(Icons.error, AppColors.danger, 'This page was not read.',
              _job.error),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _working ? null : _retry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          const SizedBox(height: 12),
        ];
      default:
        return const [];
    }
  }

  Widget _engineCard() {
    final engineText = _job.text.trim();
    return Card(
      color: AppColors.infoBg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.document_scanner, size: 18, color: AppColors.info),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('What the engine read',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              engineText.isEmpty ? '(nothing was read)' : engineText,
              style: const TextStyle(fontSize: 13.5, height: 1.45),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip('Engine: ${_job.provider}'),
                _chip('Lines: ${_job.lines}'),
                if (_job.costTier.isNotEmpty) _chip('Rate: ${_job.costTier}'),
                _chip(_job.confidence > 0
                    ? 'Confidence: ${( _job.confidence * 100).round()}%'
                    : 'Confidence: not reported'),
              ],
            ),
            for (final w in _job.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _notice(Icons.warning_amber_rounded, AppColors.warning,
                    'Worth checking', w),
              ),
          ],
        ),
      ),
    );
  }

  Widget _reviewField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your reading of this page',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
          'Correct anything the engine got wrong. Clearing it entirely is a '
          'valid answer — it means you read nothing usable here.',
          style: TextStyle(fontSize: 12, color: AppColors.muted),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _review,
          maxLines: 8,
          minLines: 5,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Type what the page actually says',
          ),
        ),
      ],
    );
  }

  Widget _confirmButton() {
    return FilledButton.icon(
      onPressed: _working ? null : _confirm,
      icon: const Icon(Icons.check),
      label: Text(_working ? 'Saving…' : 'Confirm this reading'),
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
    );
  }

  Widget _confirmedNote() {
    return Card(
      color: AppColors.successBg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.check_circle, color: AppColors.success, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Confirmed by you on ${_job.confirmedAt ?? ''}. Only this '
                'confirmed reading may be used when marking.',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notice(IconData icon, Color color, String title, String body) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style:
                        TextStyle(fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 26),
              child: Text(body, style: const TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11.5)),
      );
}
