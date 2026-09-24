import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'assessment_builder_screen.dart';
import 'assessment_repository.dart';
import 'capture_screen.dart';

class AssessmentsScreen extends StatefulWidget {
  const AssessmentsScreen({super.key});

  @override
  State<AssessmentsScreen> createState() => _AssessmentsScreenState();
}

class _AssessmentsScreenState extends State<AssessmentsScreen> {
  late Future<List<Assessment>> _data;

  @override
  void initState() {
    super.initState();
    _data = AssessmentRepository().assessments();
  }

  void _reload() => setState(() => _data = AssessmentRepository().assessments());

  Future<void> _create() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AssessmentBuilderScreen()),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Assessments'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New assessment'),
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SvLoading();
          }
          if (snap.hasError) {
            return SvErrorState(
              message: 'Could not load assessments',
              onRetry: _reload,
            );
          }
          final assessments = snap.data ?? [];
          if (assessments.isEmpty) {
            return SvEmptyState(
              icon: Icons.assignment_outlined,
              title: 'No assessments yet',
              message: 'Create the first assessment for your class.',
              actionLabel: 'New assessment',
              onAction: _create,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: assessments.length,
            itemBuilder: (context, i) {
              final a = assessments[i];
              return SvEntrance(
                delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                child: SvPressScale(
                  child: SvAvatarTile(
                  title: a.title,
                  meta:
                      '${a.type.label} · ${subjectName(a.subjectId)} · ${a.classId}',
                  icon: Icons.assignment,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${a.totalMarks.toStringAsFixed(0)} marks',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: AppTheme.brand)),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right,
                          size: 20, color: AppColors.muted),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CaptureScreen(assessment: a),
                    ),
                  ),
                ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}