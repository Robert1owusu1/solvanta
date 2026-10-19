import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/assessment.dart';
import '../../core/models/scan_page.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import 'scan_quality.dart';
import 'scans_repository.dart';

class ScanCaptureScreen extends StatefulWidget {
  const ScanCaptureScreen({
    super.key,
    required this.assessment,
    required this.student,
  });

  final Assessment assessment;
  final Student student;

  @override
  State<ScanCaptureScreen> createState() => _ScanCaptureScreenState();
}

class _ScanCaptureScreenState extends State<ScanCaptureScreen> {
  final _picker = ImagePicker();
  final _repo = ScansRepository();

  String? _imagePath;
  Uint8List? _imageBytes;
  ScanImageStats? _stats;
  List<String> _warnings = const [];
  int _pageNumber = 1;
  int _submittedPages = 0;
  bool _working = false;

  Future<void> _pick(ImageSource source) async {
    setState(() => _working = true);
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 3200,
        imageQuality: 90,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final stats = await measureImage(bytes);
      if (!mounted) return;
      setState(() {
        _imagePath = file.path;
        _imageBytes = bytes;
        _stats = stats;
        _warnings = ScanQualityCheck.evaluate(stats);
      });
    } catch (_) {
      if (mounted) {
        svSnack(context, 'Could not load the photo. Please try again.',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _retake() {
    setState(() {
      _imagePath = null;
      _imageBytes = null;
      _stats = null;
      _warnings = const [];
    });
  }

  Future<void> _submit() async {
    final user = await AuthRepository().currentUser();
    final scan = ScanPage(
      id: 'SCAN-${DateTime.now().millisecondsSinceEpoch}',
      assessmentId: widget.assessment.id,
      studentId: widget.student.id,
      imagePath: _imagePath ?? '',
      pageNumber: _pageNumber,
      capturedAt: _now(),
      recorder: user?.name ?? 'School Staff',
      status: _warnings.isEmpty ? ScanStatus.queued : ScanStatus.needsReview,
      qualityWarnings: _warnings,
    );
    await _repo.save(scan);
    if (!mounted) return;
    setState(() {
      _submittedPages++;
      _pageNumber++;
      _imagePath = null;
      _imageBytes = null;
      _stats = null;
      _warnings = const [];
    });
    svSnack(context, 'Page ${scan.pageNumber} queued for processing');
  }

  String _now() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Scan — ${widget.student.fullName}')),
      body: _working
          ? const SvLoading(message: 'Working on the photo…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: AppTheme.brand.withValues(alpha: .06),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.assessment.title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(
                          'Photograph ${widget.student.firstName}\'s answer '
                          'sheet. A quick quality check runs first and asks '
                          'for a retake if the page is dark, blurred or '
                          'sideways.',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_imagePath == null)
                  _pickOptions()
                else
                  _reviewPanel(),
                if (_submittedPages > 0) ...[
                  const SizedBox(height: 12),
                  _statusLine(),
                ],
              ],
            ),
    );
  }

  Widget _pickOptions() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _working ? null : () => _pick(ImageSource.camera),
            icon: const Icon(Icons.photo_camera),
            label: const Text('Take photo of answer sheet'),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _working ? null : () => _pick(ImageSource.gallery),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Choose from gallery'),
        ),
      ],
    );
  }

  static Widget _brokenImage(BuildContext _, Object _, StackTrace? _) =>
      Container(
        height: 200,
        color: AppColors.border,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      );

  Widget _reviewPanel() {
    final stats = _stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            // The browser has no file system: image_picker hands back a blob
            // URL there, so preview the bytes already read for the check.
            child: kIsWeb
                ? Image.memory(
                    _imageBytes!,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: _brokenImage,
                  )
                : Image.file(
                    File(_imagePath!),
                    width: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: _brokenImage,
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          color: _warnings.isEmpty
              ? AppColors.successBg
              : AppColors.warningBg,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _warnings.isEmpty
                          ? Icons.check_circle
                          : Icons.warning_amber_rounded,
                      color: _warnings.isEmpty
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _warnings.isEmpty
                          ? 'Page looks good'
                          : 'Retake recommended',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _warnings.isEmpty
                            ? AppColors.success
                            : AppColors.warning,
                      ),
                    ),
                  ],
                ),
                if (_warnings.isEmpty && stats != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '${stats.width}×${stats.height} · upright '
                    '· ${(stats.luminance * 100).round()}% brightness',
                    style: TextStyle(fontSize: 12, color: AppColors.body),
                  ),
                ],
                for (final w in _warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(w,
                              style: const TextStyle(fontSize: 12.5)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _retake,
                icon: const Icon(Icons.refresh),
                label: const Text('Retake'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.upload),
                label: const Text('Submit'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'You can still submit if a retake isn\'t practical — mark it '
          'yourself afterwards.',
          style: TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ],
    );
  }

  Widget _statusLine() {
    return Card(
      child: ListTile(
        leading: Icon(Icons.cloud_done, color: AppColors.success),
        title: Text('$_submittedPages page(s) queued for ${widget.student.firstName}'),
        subtitle: const Text('Open the student later to verify and mark the answers.'),
        trailing: TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ),
      ),
    );
  }
}