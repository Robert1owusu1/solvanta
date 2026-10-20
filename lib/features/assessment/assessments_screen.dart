import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/subjects.dart';
import '../../core/responsive.dart';
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
          return ResponsiveBuilder(
            phone: (context) => ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: assessments.length,
              itemBuilder: (context, i) => _AssessmentListItem(assessment: assessments[i], index: i),
            ),
            tablet: (context) => _AssessmentGrid(assessments: assessments),
            desktop: (context) => _AssessmentGrid(assessments: assessments, minItemWidth: 350),
          );
        },
      ),
    );
  }
}

class _AssessmentListItem extends StatelessWidget {
  const _AssessmentListItem({required this.assessment, required this.index});

  final Assessment assessment;
  final int index;

  @override
  Widget build(BuildContext context) {
    return SvEntrance(
      delay: Duration(milliseconds: 40 * index.clamp(0, 10)),
      child: SvPressScale(
        child: SvAvatarTile(
        title: assessment.title,
        meta:
            '${assessment.type.label} · ${subjectName(assessment.subjectId)} · ${assessment.classId}',
        icon: Icons.assignment,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${assessment.totalMarks.toStringAsFixed(0)} marks',
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
            builder: (_) => CaptureScreen(assessment: assessment),
          ),
        ),
      ),
      ),
    );
  }
}

class _AssessmentGrid extends StatelessWidget {
  const _AssessmentGrid({required this.assessments, this.minItemWidth = 300});

  final List<Assessment> assessments;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) {
    return ResponsiveGridView(
      minItemWidth: minItemWidth,
      maxColumns: 4,
      minColumns: 2,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      padding: const EdgeInsets.all(16),
      baseAspectRatio: 1.5,
      children: [
        for (var i = 0; i < assessments.length; i++)
          SvEntrance(
            delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
            child: SvPressScale(
              child: _AssessmentGridCard(assessment: assessments[i]),
            ),
          ),
      ],
    );
  }
}

class _AssessmentGridCard extends StatelessWidget {
  const _AssessmentGridCard({required this.assessment});

  final Assessment assessment;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CaptureScreen(assessment: assessment),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTheme.navy900, AppTheme.navy700],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.assignment, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          assessment.type.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.brand,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          subjectName(assessment.subjectId),
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                assessment.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.ink),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.grade_outlined, size: 14, color: AppColors.muted),
                  const SizedBox(width: 4),
                  Text(
                    '${assessment.totalMarks.toStringAsFixed(0)} marks',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: AppColors.muted),
                  ),
                  const Spacer(),
                  Text(
                    assessment.classId,
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CaptureScreen(assessment: assessment),
                      ),
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: const Text('Open'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.brand,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
