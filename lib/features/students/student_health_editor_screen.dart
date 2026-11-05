import 'package:flutter/material.dart';

import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../audit/audit_repository.dart';
import 'students_repository.dart';

/// Edits one pupil's emergency medical record. List fields are entered one item
/// per line (commas also split), so a staff member can paste or type a short
/// list without a chip editor. Saving writes through the normal student save, so
/// the record syncs with everything else on the profile.
class StudentHealthEditorScreen extends StatefulWidget {
  const StudentHealthEditorScreen({super.key, required this.student});

  final Student student;

  @override
  State<StudentHealthEditorScreen> createState() =>
      _StudentHealthEditorScreenState();
}

class _StudentHealthEditorScreenState extends State<StudentHealthEditorScreen> {
  static const _bloodGroups = [
    '',
    'A+',
    'A-',
    'B+',
    'B-',
    'AB+',
    'AB-',
    'O+',
    'O-',
  ];

  late final StudentHealth _h = widget.student.health ?? const StudentHealth();
  late String _bloodGroup =
      _bloodGroups.contains(_h.bloodGroup) ? _h.bloodGroup : '';
  late final _allergies = TextEditingController(text: _h.allergies.join('\n'));
  late final _conditions = TextEditingController(text: _h.conditions.join('\n'));
  late final _medications =
      TextEditingController(text: _h.medications.join('\n'));
  late final _immunizations =
      TextEditingController(text: _h.immunizations.join('\n'));
  late final _notes = TextEditingController(text: _h.notes);
  bool _saving = false;

  @override
  void dispose() {
    _allergies.dispose();
    _conditions.dispose();
    _medications.dispose();
    _immunizations.dispose();
    _notes.dispose();
    super.dispose();
  }

  // Splits on newlines or commas, trims, and drops blanks — so "peanuts,\n
  // shellfish" and one-per-line both become a clean list.
  List<String> _parse(TextEditingController c) => [
        for (final raw in c.text.split(RegExp(r'[\n,]')))
          if (raw.trim().isNotEmpty) raw.trim(),
      ];

  Future<void> _save() async {
    setState(() => _saving = true);
    final health = StudentHealth(
      bloodGroup: _bloodGroup,
      allergies: _parse(_allergies),
      conditions: _parse(_conditions),
      medications: _parse(_medications),
      immunizations: _parse(_immunizations),
      notes: _notes.text.trim(),
    );
    final updated = widget.student.copyWith(health: health);
    await StudentsRepository().saveStudent(updated);
    await AuditRepository().log(
      action: 'student.health.update',
      actor: 'Staff',
      target: widget.student.id,
      detail: 'Updated health record for ${widget.student.fullName}',
      reason: 'Emergency medical record edit',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Health record saved')),
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Health & emergency')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.student.fullName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'An emergency medical record, visible to school staff and the '
            'child\'s own family. Enter one item per line.',
            style: TextStyle(color: AppColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            initialValue: _bloodGroup,
            decoration: const InputDecoration(
              labelText: 'Blood group',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final g in _bloodGroups)
                DropdownMenuItem(
                    value: g, child: Text(g.isEmpty ? '— not recorded —' : g)),
            ],
            onChanged: (v) => setState(() => _bloodGroup = v ?? ''),
          ),
          const SizedBox(height: 16),
          _listField(_allergies, 'Allergies', Icons.warning_amber,
              'e.g. Peanuts\nPenicillin'),
          _listField(_conditions, 'Conditions', Icons.healing_outlined,
              'e.g. Asthma\nSickle cell'),
          _listField(_medications, 'Medications', Icons.medication_outlined,
              'e.g. Salbutamol inhaler'),
          _listField(_immunizations, 'Immunizations', Icons.vaccines_outlined,
              'e.g. BCG\nMeasles'),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Notes',
              prefixIcon: Icon(Icons.notes_outlined),
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('Save health record'),
          ),
        ],
      ),
    );
  }

  Widget _listField(TextEditingController c, String label, IconData icon,
      String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: c,
        minLines: 1,
        maxLines: 4,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
    );
  }
}
