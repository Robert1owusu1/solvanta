import 'package:flutter/material.dart';

import '../../core/models/gate_event.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'safety_repository.dart';

class SafetyGateScreen extends StatefulWidget {
  const SafetyGateScreen({super.key});

  @override
  State<SafetyGateScreen> createState() => _SafetyGateScreenState();
}

class _SafetyGateScreenState extends State<SafetyGateScreen> {
  late Future<(List<GateEvent>, List<Student>, String)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<(List<GateEvent>, List<Student>, String)> _load() async {
    final events = await SafetyRepository().forDate(_today());
    final students = await StudentsRepository().all();
    final reporter = (await AuthRepository().currentUser())?.name ??
        'School Staff';
    return (events, students, reporter);
  }

  Future<void> _record() async {
    final (_, students, reporter) = await _data;
    if (!mounted) return;

    Student? selected;
    var chosenStudentName = '';
    String chosenAction = 'arrival';

    final outcome = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .stretch,
              children: [
                const Text('Record gate event',
                    textAlign: .center,
                    style: TextStyle(fontSize: 18, fontWeight: .w700)),
                const SizedBox(height: 16),
                DropdownButtonFormField<Student>(
                  initialValue: selected,
                  hint: const Text('Select student'),
                  // "name · class" is dynamic — expanded + ellipsis keeps it
                  // sharing the row with the arrow (no right overflow).
                  isExpanded: true,
                  items: [
                    for (final s in students)
                      DropdownMenuItem(
                        value: s,
                        child: Text(
                          '${s.fullName} · ${s.classId}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                  ],
                  onChanged: (v) => setSheet(() => selected = v),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'arrival',
                        label: Text('Arrived'),
                        icon: Icon(Icons.login)),
                    ButtonSegment(
                        value: 'departure',
                        label: Text('Departed'),
                        icon: Icon(Icons.logout)),
                    ButtonSegment(
                        value: 'pickup',
                        label: Text('Pickup'),
                        icon: Icon(Icons.verified_user)),
                  ],
                  selected: {chosenAction},
                  onSelectionChanged: (s) =>
                      setSheet(() => chosenAction = s.first),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: selected == null
                      ? null
                      : () async {
                          final student = selected!;
                          chosenStudentName = student.fullName;
                          String? outcome;
                          if (chosenAction == 'pickup') {
                            outcome = await _verifyPickup(
                                sheetCtx, student, reporter);
                          } else {
                            final type = chosenAction == 'arrival'
                                ? GateEventType.arrival
                                : GateEventType.departure;
                            await SafetyRepository().record(
                              studentId: student.id,
                              type: type,
                              reporter: reporter,
                              detail: '${type.label} at gate',
                            );
                          }
                          if (sheetCtx.mounted) {
                            Navigator.of(sheetCtx).pop(outcome);
                          }
                        },
                  child: const Text('Save event'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    setState(() { _data = _load(); });
    if (!mounted) return;
    if (outcome != null && outcome.startsWith('UNAUTHORIZED:')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${outcome.substring(13)} is NOT authorized '
              'to pick up $chosenStudentName'),
          backgroundColor: AppColors.danger,
        ),
      );
    } else if (outcome != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$outcome verified and released'),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  Future<String?> _verifyPickup(
      BuildContext sheetCtx, Student student, String reporter) async {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();

    final outcome = await showDialog<String>(
      context: sheetCtx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Verify pickup'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Pickup person name or phone',
              helperText: 'Matched against the authorized pickup list',
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final query = controller.text.trim();
              final missing = Person(name: '', phone: '');
              final match = student.authorizedPickup.firstWhere(
                (p) =>
                    p.name.toLowerCase() == query.toLowerCase() ||
                    p.phone.replaceAll(' ', '') == query.replaceAll(' ', ''),
                orElse: () => missing,
              );
              if (match.name.isEmpty) {
                Navigator.of(dialogCtx).pop('UNAUTHORIZED:$query');
              } else {
                Navigator.of(dialogCtx).pop(match.name);
              }
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );

    if (outcome == null) return null;
    if (outcome.startsWith('UNAUTHORIZED:')) {
      final query = outcome.substring(13);
      await SafetyRepository().record(
        studentId: student.id,
        type: GateEventType.unauthorizedPickup,
        reporter: reporter,
        person: query,
        detail: 'Pickup by unverified person — parent alerted',
      );
      return 'UNAUTHORIZED:$query';
    }
    await SafetyRepository().record(
      studentId: student.id,
      type: GateEventType.pickupAuthorized,
      reporter: reporter,
      person: outcome,
      detail: 'Pickup verified against authorized list',
    );
    return outcome;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Student Safety Gate'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _record,
        icon: const Icon(Icons.add),
        label: const Text('Record event'),
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final (events, students, _) = snap.data ?? (<GateEvent>[], <Student>[], '');
          if (events.isEmpty) {
            return const Center(child: Text('No gate activity today'));
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final e = events[i];
              final s = students.where((s) => s.id == e.studentId);
              final name = s.isEmpty ? e.studentId : s.first.fullName;
              final color = _colorFor(e.type);
              return SvEntrance(
                delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
                child: SvPressScale(
                  child: SvAvatarTile(
                  title: name,
                  meta: '${e.type.label} · ${e.detail}',
                  icon: _iconFor(e.type),
                  avatarColor: color,
                  trailing: Text(e.time,
                      style: TextStyle(
                          color: AppColors.muted,
                          fontWeight: .w600,
                          fontSize: 12)),
                ),
              ),
              );
          },
        );
      },
    ),
    );
  }

  Color _colorFor(GateEventType t) => switch (t) {
        GateEventType.arrival || GateEventType.departure => AppTheme.brand,
        GateEventType.pickupAuthorized => AppColors.success,
        GateEventType.unauthorizedPickup => AppColors.danger,
        GateEventType.earlyDeparture => AppColors.warning,
      };

  IconData _iconFor(GateEventType t) => switch (t) {
        GateEventType.arrival => Icons.login,
        GateEventType.departure => Icons.logout,
        GateEventType.pickupAuthorized => Icons.verified_user_outlined,
        GateEventType.unauthorizedPickup => Icons.gpp_bad_outlined,
        GateEventType.earlyDeparture => Icons.schedule,
      };
}