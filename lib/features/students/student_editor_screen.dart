import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/class_room.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../admin/admin_repository.dart';
import 'students_repository.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

class StudentEditorScreen extends StatefulWidget {
  const StudentEditorScreen({super.key, this.initial});

  final Student? initial;

  @override
  State<StudentEditorScreen> createState() => _StudentEditorScreenState();
}

class _StudentEditorScreenState extends State<StudentEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _first = TextEditingController(text: widget.initial?.firstName ?? '');
  late final _last = TextEditingController(text: widget.initial?.lastName ?? '');
  late final _dob = TextEditingController(text: widget.initial?.dateOfBirth ?? '');
  late final _admissionNo =
      TextEditingController(text: widget.initial?.admissionNo ?? '');
  late String _classId = widget.initial?.classId ?? '';
  late String _gender = widget.initial?.gender.isNotEmpty == true
      ? widget.initial!.gender
      : 'M';
  late String _photoUrl = widget.initial?.photoUrl ?? '';
  final _picker = ImagePicker();
  bool _pickingPhoto = false;

  late List<Person> _guardians =
      List.of(widget.initial?.guardians ?? const []);
  late List<Person> _emergency =
      List.of(widget.initial?.emergencyContacts ?? const []);
  late List<Person> _pickup =
      List.of(widget.initial?.authorizedPickup ?? const []);

  late Future<List<ClassRoom>> _classesFuture;
  late Future<List<User>> _parentsFuture;
  String? _parentUserId;

  @override
  void initState() {
    super.initState();
    _classesFuture = StudentsRepository().classes();
    _parentsFuture = AdminRepository().parentUsers();
    _parentUserId = widget.initial?.parentUserId;
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _dob.dispose();
    _admissionNo.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (_pickingPhoto) return;
    setState(() => _pickingPhoto = true);
    try {
      // Passport-sized: small enough to carry in the student record as a
      // base64 data URI without bloating the sync payload.
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 600,
        maxHeight: 800,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 600 * 1024) {
        if (mounted) {
          svSnack(context,
              'That photo is too large. Pick a smaller / more cropped image.',
              error: true);
        }
        return;
      }
      if (!mounted) return;
      setState(() => _photoUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}');
    } catch (_) {
      if (mounted) svSnack(context, 'Could not add the photo.', error: true);
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  void _photoSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.gallery);
              },
            ),
            if (_photoUrl.isNotEmpty)
              ListTile(
                leading: Icon(Icons.delete_outline, color: AppColors.danger),
                title: const Text('Remove photo'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _photoUrl = '');
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = StudentsRepository();
    final existing = await repo.all();
    final student = Student(
      id: widget.initial?.id ?? await repo.nextStudentId(existing),
      firstName: _first.text.trim(),
      lastName: _last.text.trim(),
      gender: _gender,
      dateOfBirth: _dob.text.trim(),
      admissionDate:
          widget.initial?.admissionDate ?? _today(),
      admissionNo: _admissionNo.text.trim().isEmpty
          ? widget.initial?.admissionNo ??
              'S-${_today().substring(0, 4)}-${(existing.length + 1).toString().padLeft(3, '0')}'
          : _admissionNo.text.trim(),
      classId: _classId,
      schoolId: widget.initial?.schoolId ?? 'SCH-001',
      status: widget.initial?.status ?? 'Active',
      parentUserId: _parentUserId,
      photoUrl: _photoUrl,
      guardians: _guardians,
      emergencyContacts: _emergency,
      authorizedPickup: _pickup,
      // Preserve the pupil's medical record, which this form does not edit.
      health: widget.initial?.health,
    );
    await repo.saveStudent(student);
    if (_parentUserId != null &&
        _parentUserId != widget.initial?.parentUserId) {
      await AdminRepository().linkParentToStudent(
          parentUserId: _parentUserId!, studentId: student.id);
    }
    if (!mounted) return;
    Navigator.of(context).pop(student);
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Enroll student' : 'Edit student'),
      ),
      body: FutureBuilder(
        future: _classesFuture,
        builder: (context, snap) {
          final classes = snap.data ?? <ClassRoom>[];
          return FutureBuilder<List<User>>(
            future: _parentsFuture,
            builder: (context, ps) {
              final parents = ps.data ?? <User>[];
              return Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _section('Basic details', [
                      Center(
                        child: Column(
                          children: [
                            GestureDetector(
                              onTap: _pickingPhoto ? null : _photoSheet,
                              child: Stack(
                                alignment: Alignment.bottomRight,
                                children: [
                                  SvPhotoAvatar(
                                    photoUrl: _photoUrl,
                                    fallbackText:
                                        '${_first.text.isNotEmpty ? _first.text[0] : ''}'
                                        '${_last.text.isNotEmpty ? _last.text[0] : ''}',
                                    size: 88,
                                    square: true,
                                    borderColor: AppColors.border,
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: AppColors.brand,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: _pickingPhoto
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white))
                                        : const Icon(Icons.photo_camera,
                                            size: 16, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text('Student photo',
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.muted)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _first,
                        decoration: const InputDecoration(labelText: 'First name'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _last,
                        decoration: const InputDecoration(labelText: 'Last name'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _gender,
                        decoration: const InputDecoration(labelText: 'Gender'),
                        items: const [
                          DropdownMenuItem(value: 'M', child: Text('Male')),
                          DropdownMenuItem(value: 'F', child: Text('Female')),
                        ],
                        onChanged: (v) => setState(() => _gender = v ?? 'M'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _dob,
                        decoration: const InputDecoration(
                            labelText: 'Date of birth (YYYY-MM-DD)'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _admissionNo,
                        decoration: const InputDecoration(
                            labelText: 'Admission number'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _classId,
                        decoration: const InputDecoration(labelText: 'Class'),
                        items: [
                          for (final c in classes)
                            DropdownMenuItem(
                                value: c.id, child: Text(c.displayName)),
                        ],
                        onChanged: (v) => setState(() => _classId = v ?? ''),
                      ),
                    ]),
                    const SizedBox(height: 16),
                    _section('Parent / guardian', [
                      DropdownButtonFormField<String>(
                        initialValue: _parentUserId,
                        // Parent labels carry a dynamic name — expanded +
                        // ellipsis keeps them off the field's right edge.
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Linked parent account (optional)'),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('No parent account')),
                          for (final p in parents)
                            DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                '${p.name} — ${p.studentIds.length} linked',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                        ],
                        onChanged: (v) =>
                            setState(() => _parentUserId = v == '' ? null : v),
                      ),
                      if (_parentUserId != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'The parent will see this child in arrivals, results, '
                            'attendance and learning support.',
                            style: TextStyle(
                                fontSize: 12, color: AppColors.muted),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    _personEditor('Guardians', _guardians,
                        (v) => setState(() => _guardians = v)),
                    const SizedBox(height: 12),
                    _personEditor(
                        'Emergency contacts', _emergency,
                        (v) => setState(() => _emergency = v)),
                    const SizedBox(height: 12),
                    _personEditor('Authorized pickup persons', _pickup,
                        (v) => setState(() => _pickup = v)),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _save,
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16)),
                      child:
                          Text(widget.initial == null ? 'Enroll student' : 'Save changes'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: children))),
        ],
      );

  Widget _personEditor(
    String title,
    List<Person> people,
    ValueChanged<List<Person>> onChange,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < people.length; i++)
                ListTile(
                  dense: true,
                  title: Text(people[i].name),
                  subtitle: Text(
                      '${people[i].phone}${people[i].relation.isNotEmpty ? ' · ${people[i].relation}' : ''}'),
                  trailing: IconButton(
                    tooltip: 'Remove ${people[i].name}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => onChange(
                        [...people]..removeAt(i)),
                  ),
                ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.add),
                title: const Text('Add person'),
                onTap: () async {
                  final result = await _addPersonDialog();
                  if (result != null) onChange([...people, result]);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<Person?> _addPersonDialog() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final relation = TextEditingController();
    return showDialog<Person>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add person'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name')),
            TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'Phone')),
            TextField(
                controller: relation,
                decoration: const InputDecoration(labelText: 'Relation')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return;
              Navigator.pop(
                  ctx,
                  Person(
                      name: name.text.trim(),
                      phone: phone.text.trim(),
                      relation: relation.text.trim()));
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}