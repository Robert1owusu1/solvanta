import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/assignment.dart';
import '../../core/models/assignment_submission.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'assignment_crop_screen.dart';
import 'assignment_submissions_repository.dart';

/// Step 1: pick whose work is being photographed.
///
/// The typed field is the primary control, not a consolation prize. It mirrors
/// the typed-ID fallback on the student ID scanner deliberately: a camera that
/// will not start, a cracked lens or a dark corridor must never be the reason
/// a teacher cannot hand in a student's work. Scanning is the shortcut; typing
/// is the route that always works.
class AssignmentStudentPickerScreen extends StatefulWidget {
  const AssignmentStudentPickerScreen({super.key, required this.assignment});

  final Assignment assignment;

  @override
  State<AssignmentStudentPickerScreen> createState() =>
      _AssignmentStudentPickerScreenState();
}

class _AssignmentStudentPickerScreenState
    extends State<AssignmentStudentPickerScreen> {
  final _query = TextEditingController();
  List<Student> _all = const [];
  List<Student> _filtered = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _query.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final students =
        await StudentsRepository().byClass(widget.assignment.classId);
    if (!mounted) return;
    setState(() {
      _all = students;
      _filtered = students;
      _loading = false;
    });
    _applyFilter();
  }

  void _applyFilter() {
    final needle = _query.text.trim().toLowerCase();
    setState(() {
      _filtered = needle.isEmpty
          ? _all
          : _all
              .where((s) =>
                  s.id.toLowerCase().contains(needle) ||
                  s.admissionNo.toLowerCase().contains(needle) ||
                  s.fullName.toLowerCase().contains(needle))
              .toList();
    });
  }

  Future<void> _open(Student s) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AssignmentCaptureScreen(
          assignment: widget.assignment,
          student: s,
        ),
      ),
    );
    if (changed == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Submit work — ${widget.assignment.title}')),
      body: _loading
          ? const SvLoading()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: _query,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      labelText: 'Student name or admission number',
                      hintText: 'Type to find the student',
                      prefixIcon: const Icon(Icons.person_search_outlined),
                      // Made explicit that typing is the intended route, so
                      // nobody reads a missing camera as a dead end.
                      helperText: 'No camera? Type the admission number instead.',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_filtered.isEmpty)
                  Expanded(
                    child: SvEmptyState(
                      icon: Icons.person_off_outlined,
                      title: 'No matching student',
                      message: _all.isEmpty
                          ? 'There are no students in ${widget.assignment.classId} yet.'
                          : 'Check the spelling, or the admission number.',
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _filtered.length,
                      itemBuilder: (context, i) {
                        final s = _filtered[i];
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  AppTheme.brand.withValues(alpha: .12),
                              child: Text(s.initials,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.brand,
                                      fontSize: 12)),
                            ),
                            title: Text(s.fullName,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(s.admissionNo),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _open(s),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Step 2: build ONE submission out of any number of photographed pages.
///
/// The flow this screen replaces treated every page as its own submission —
/// a five-page booklet meant five separate uploads that whoever marked had to
/// find and reassemble by hand. Here pages accumulate into a list, and a
/// single Submit writes one record carrying all of them.
class AssignmentCaptureScreen extends StatefulWidget {
  const AssignmentCaptureScreen({
    super.key,
    required this.assignment,
    required this.student,
  });

  final Assignment assignment;
  final Student student;

  @override
  State<AssignmentCaptureScreen> createState() => _AssignmentCaptureScreenState();
}

/// One page held in memory before the submission is written.
class _HeldPage {
  _HeldPage({
    required this.id,
    required this.bytes,
    required this.warnings,
  });

  final String id;
  final Uint8List bytes;
  final List<String> warnings;
}

class _AssignmentCaptureScreenState extends State<AssignmentCaptureScreen> {
  final _picker = ImagePicker();
  final _repo = AssignmentSubmissionsRepository();
  final _notes = TextEditingController();

  /// Pages held locally, in order. Kept as bytes because on the browser there
  /// is no file to re-read, and because the teacher is still editing.
  final List<_HeldPage> _pages = [];

  String? _submissionId;
  String _recorder = '';
  bool _saving = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _resume();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// Reopens the student's existing submission if one is already open, so
  /// photographing a booklet across two sittings still produces one record
  /// rather than two that a marker has to reconcile.
  Future<void> _resume() async {
    final existing = await _repo.openFor(widget.assignment.id, widget.student.id);
    final user = await AuthRepository().currentUser();
    if (!mounted) return;
    setState(() {
      _submissionId = existing?.id;
      _notes.text = existing?.manualNotes ?? '';
      _recorder = existing?.recorder ?? user?.name ?? 'School Staff';
    });
  }

  String get _submissionIdOrNew =>
      _submissionId ??= 'ASUB-${DateTime.now().millisecondsSinceEpoch}';

  String _now() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// Takes a photo or picks one, then runs it through crop, rotate and the
  /// quality gate before it is allowed to join the submission.
  Future<void> _addPage(ImageSource source) async {
    setState(() => _working = true);
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 3200,
        imageQuality: 90,
      );
      if (file == null) {
        if (mounted) setState(() => _working = false);
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      // Hand off to the crop/rotate screen. It returns the adjusted bytes and
      // the advisory warnings, or null when the teacher backs out.
      final result = await Navigator.of(context).push<PageCropResult>(
        MaterialPageRoute(builder: (_) => AssignmentCropScreen(bytes: bytes)),
      );
      if (!mounted) return;
      setState(() => _working = false);
      if (result == null) return;
      setState(() {
        _pages.add(_HeldPage(
          id: 'APAGE-${DateTime.now().millisecondsSinceEpoch}',
          bytes: result.bytes,
          warnings: result.warnings,
        ));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _working = false);
      svSnack(context, 'Could not load that photo. Please try again.',
          error: true);
    }
  }

  void _removePage(_HeldPage page) {
    setState(() => _pages.remove(page));
  }

  /// Writes ONE submission carrying every page, plus any manual notes.
  Future<void> _submit() async {
    if (_pages.isEmpty && _notes.text.trim().isEmpty) {
      svSnack(context, 'Add at least one page, or type the answers instead.',
          error: true);
      return;
    }
    setState(() => _saving = true);

    final submission = AssignmentSubmission(
      id: _submissionIdOrNew,
      assignmentId: widget.assignment.id,
      studentId: widget.student.id,
      classId: widget.assignment.classId,
      subjectId: widget.assignment.subjectId,
      recorder: _recorder,
      capturedAt: _now(),
      pages: [
        for (var i = 0; i < _pages.length; i++)
          AssignmentPage(
            id: _pages[i].id,
            pageNumber: i + 1,
            imagePath: '',
            capturedAt: _now(),
            qualityWarnings: _pages[i].warnings,
          )
      ],
      manualNotes: _notes.text.trim(),
      // A page that needed an override, or notes typed instead of a photo, is
      // exactly the case a second pair of eyes should catch — so it is flagged
      // rather than passed off as a clean capture.
      status: _pages.any((p) => p.warnings.isNotEmpty) ||
              _pages.isEmpty
          ? AssignmentSubmissionStatus.needsReview
          : AssignmentSubmissionStatus.queued,
    );

    try {
      await _repo.save(
        submission,
        images: {
          for (final p in _pages) p.id: p.bytes,
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      svSnack(context, 'Could not save the submission. Please try again.',
          error: true);
      return;
    }

    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.student;
    return Scaffold(
      appBar: AppBar(title: Text(s.fullName)),
      body: _working
          ? const SvLoading(message: 'Preparing the page…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _header(),
                const SizedBox(height: 12),
                _pagesCard(),
                const SizedBox(height: 12),
                _manualCard(),
                const SizedBox(height: 88),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload),
            label: Text(_saving
                ? 'Saving…'
                : _pages.isEmpty
                    ? 'Submit typed answers'
                    : 'Submit ${_pages.length} page${_pages.length == 1 ? '' : 's'}'),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Card(
      color: AppTheme.brand.withValues(alpha: .06),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.assignment.title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'Photograph every page of the work. They are kept together as '
              'one submission, in order.',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pagesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.collections_outlined, size: 20),
                const SizedBox(width: 8),
                Text('Pages (${_pages.length})',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ],
            ),
            if (_pages.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'No pages yet. Add the first page below.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.muted),
                ),
              ),
            for (final page in _pages) _pageTile(page),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _working ? null : () => _addPage(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('Add page'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _working ? null : () => _addPage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('From gallery'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageTile(_HeldPage page) {
    final index = _pages.indexOf(page);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              page.bytes,
              width: 54,
              height: 70,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                width: 54,
                height: 70,
                color: AppColors.border,
                child: const Icon(Icons.broken_image_outlined, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Page ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (page.warnings.isEmpty)
                  Text('Ready to submit',
                      style: TextStyle(fontSize: 11.5, color: AppColors.muted))
                else
                  for (final w in page.warnings)
                    Text('Reshoot advised: $w',
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.warning)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove page ${index + 1}',
            icon: Icon(Icons.delete_outline, color: AppColors.danger),
            onPressed: () => _removePage(page),
          ),
        ],
      ),
    );
  }

  Widget _manualCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note_outlined, size: 20),
                const SizedBox(width: 8),
                const Text('No camera? Type the answers',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The same fallback as the ID scanner: if the camera will not '
              'start or the photo will not come out, write the answers in '
              'here instead. They are saved with the same submission.',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _notes,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Type the student\'s answers here…',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }
}
