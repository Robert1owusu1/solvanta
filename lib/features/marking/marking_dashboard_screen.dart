import 'package:flutter/material.dart';

import '../../core/models/assessment.dart';
import '../../core/models/student.dart';
import '../../core/models/submission.dart';
import '../../core/models/subjects.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../assessment/assessment_repository.dart';
import '../students/students_repository.dart';
import 'draft_review_screen.dart';
import 'marking_screen.dart';

class MarkingDashboardScreen extends StatefulWidget {
  const MarkingDashboardScreen({super.key});

  @override
  State<MarkingDashboardScreen> createState() => _MarkingDashboardScreenState();
}

class _MarkingDashboardScreenState extends State<MarkingDashboardScreen> {
  late Future<(List<Assessment>, List<Student>, List<AssessmentSubmission>)>
      _data;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<Assessment>, List<Student>, List<AssessmentSubmission>)>
      _load() async {
    final repo = AssessmentRepository();
    final assessments = await repo.assessments();
    final students = await StudentsRepository().all();
    final subs = await repo.submissions();
    _selectedId ??= assessments.isNotEmpty ? assessments.first.id : null;
    return (assessments, students, subs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Marking Dashboard',
        actions: [
          IconButton(
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: 'AI Marking Review',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DraftReviewQueueScreen()),
            ),
          ),
        ],
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load marking",
              message: 'We couldn\'t load the marking list. Please try again.',
              onRetry: () => setState(() { _data = _load(); }),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton();
          }
          final (assessments, students, subs) =
              snap.data ?? (<Assessment>[], <Student>[], <AssessmentSubmission>[]);
          if (assessments.isEmpty) {
            return const SvEmptyState(
              icon: Icons.grading_outlined,
              title: 'No assessments to mark yet',
              message: 'Create an assessment with questions first, then '
                  'mark student answers here.',
            );
          }
          final selected = assessments.firstWhere(
            (a) => a.id == _selectedId,
            orElse: () => assessments.first,
          );
          final roster =
              students.where((s) => s.classId == selected.classId).toList();
          return Column(
            crossAxisAlignment: .stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<String>(
                  initialValue: selected.id,
                  // Long "title · subject" labels must share the row with the
                  // dropdown arrow — expanded + ellipsis keeps them from
                  // painting past the field's right edge.
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Assessment'),
                  items: [
                    for (final a in assessments)
                      DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            '${a.title} · ${subjectName(a.subjectId)}',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          )),
                  ],
                  onChanged: (v) => setState(() {
                    _selectedId = v;
                    _data = _load();
                  }),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                    '${selected.totalMarks.toStringAsFixed(0)} marks · '
                    '${selected.questions.length} questions · ${roster.length} students',
                    style: TextStyle(color: AppColors.muted)),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: roster.length,
                  itemBuilder: (context, i) {
                    final s = roster[i];
                    final sub = subs.firstWhere(
                      (x) =>
                          x.assessmentId == selected.id && x.studentId == s.id,
                      orElse: () => AssessmentSubmission(
                        id: '',
                        assessmentId: selected.id,
                        studentId: s.id,
                        classId: selected.classId,
                        date: '',
                        answers: const {},
                        teacherMarks: const {},
                        earned: 0,
                      ),
                    );
                    final marked = sub.id.isNotEmpty;
                    return SvEntrance(
                      delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                      child: SvPressScale(
                        child: SvAvatarTile(
                      title: s.fullName,
                      meta: marked
                          ? 'Marked — ${sub.earned.toStringAsFixed(1)} / ${selected.totalMarks.toStringAsFixed(1)} marks'
                          : 'Awaiting marking',
                      initials: s.initials,
                      avatarColor: marked
                          ? AppColors.success
                          : AppColors.notAttempted,
                      trailing: Icon(
                          marked
                              ? Icons.check_circle
                              : Icons.auto_awesome_motion,
                          color: marked
                              ? AppColors.success
                              : AppColors.notAttempted),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MarkingScreen(
                                assessment: selected, student: s),
                          ),
                        );
                        setState(() { _data = _load(); });
                      },
                    ),
                  ),
                );
                },
              ),
            ),
            ],
          );
        },
      ),
    );
  }
}