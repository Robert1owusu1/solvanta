import 'package:flutter/material.dart';

import '../../core/models/class_room.dart';
import '../../core/models/school.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../audit/audit_repository.dart';
import '../students/students_repository.dart';
import 'admin_repository.dart';
import 'grading_settings_screen.dart';

class SchoolAdminScreen extends StatefulWidget {
  const SchoolAdminScreen({super.key});

  @override
  State<SchoolAdminScreen> createState() => _SchoolAdminScreenState();
}

class _SchoolAdminScreenState extends State<SchoolAdminScreen> {
  late Future<(School?, List<ClassRoom>, List<int>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(School?, List<ClassRoom>, List<int>)> _load() async {
    final school = await AdminRepository().school();
    final classes = await AdminRepository().classes();
    final students = await StudentsRepository().active();
    final rosterCounts = [
      for (final c in classes)
        students.where((s) => s.classId == c.id).length,
    ];
    return (school, classes, rosterCounts);
  }

  void _refresh() => setState(() { _data = _load(); });

  Future<void> _editSchool(School school) async {
    final name = TextEditingController(text: school.name);
    final motto = TextEditingController(text: school.motto);
    final address = TextEditingController(text: school.address);
    final phone = TextEditingController(text: school.phone);
    final email = TextEditingController(text: school.email);
    final region = TextEditingController(text: school.region);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('School details',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'School name')),
              const SizedBox(height: 12),
              TextField(controller: motto, decoration: const InputDecoration(labelText: 'Motto')),
              const SizedBox(height: 12),
              TextField(controller: address, decoration: const InputDecoration(labelText: 'Address')),
              const SizedBox(height: 12),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
              const SizedBox(height: 12),
              TextField(controller: email, decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(controller: region, decoration: const InputDecoration(labelText: 'Region')),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () async {
                    await AdminRepository().saveSchool(School(
                      id: school.id,
                      name: name.text.trim().isEmpty ? school.name : name.text.trim(),
                      motto: motto.text.trim(),
                      address: address.text.trim(),
                      phone: phone.text.trim(),
                      email: email.text.trim(),
                      region: region.text.trim(),
                    ));
                    await AuditRepository().log(
                      action: 'school.update',
                      actor: 'Admin',
                      target: school.id,
                      detail: 'School details updated',
                      reason: 'Administrative update',
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    _refresh();
                  },
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _upsertClass({ClassRoom? existing}) async {
    final name = TextEditingController(text: existing?.name ?? 'JHS1');
    final stream = TextEditingController(text: existing?.stream ?? 'A');
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add class' : 'Edit class'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. JHS1)')),
            const SizedBox(height: 12),
            TextField(controller: stream, decoration: const InputDecoration(labelText: 'Stream (e.g. A)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final trimmedName = name.text.trim();
              if (trimmedName.isEmpty) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Class name cannot be empty')),
                  );
                }
                return;
              }
              final id =
                  '${trimmedName.toUpperCase()}${stream.text.trim().toUpperCase()}';
              final repo = AdminRepository();
              final classes = await repo.classes();
              final without = classes.where((c) => c.id != existing?.id).toList();
              await repo.saveClasses([
                ...without,
                ClassRoom(
                    id: existing?.id ?? id,
                    name: trimmedName.toUpperCase(),
                    stream: stream.text.trim().toUpperCase(),
                    teacherId: existing?.teacherId),
              ]);
              await AuditRepository().log(
                action: existing == null ? 'class.add' : 'class.update',
                actor: 'Admin',
                target: id,
                detail: '$trimmedName${stream.text}',
                reason: 'Class management',
              );
              if (ctx.mounted) Navigator.pop(ctx);
              _refresh();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'School & Classes'),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final school = snap.data?.$1;
          final classes = snap.data?.$2 ?? const <ClassRoom>[];
          final roster = snap.data?.$3 ?? const <int>[];
          if (school == null) {
            return const Center(child: Text('School not configured'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: AppTheme.brand.withValues(alpha: .14),
                            child: Text(school.id.replaceAll('SCH-', ''),
                                style: TextStyle(
                                    color: AppColors.brand, fontWeight: .w800)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(school.name,
                                    style: const TextStyle(
                                        fontSize: 18, fontWeight: .w700)),
                                if (school.motto.isNotEmpty)
                                  Text(school.motto,
                                      style: TextStyle(
                                          color: AppColors.muted,
                                          fontStyle: FontStyle.italic)),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit school details',
                            icon: const Icon(Icons.edit),
                            onPressed: () => _editSchool(school),
                          ),
                        ],
                      ),
                      const Divider(),
                      for (final row in [
                        (Icons.location_on_outlined, school.address),
                        (Icons.phone_outlined, school.phone),
                        (Icons.email_outlined, school.email),
                        (Icons.map_outlined, school.region),
                      ])
                        if (row.$2.isNotEmpty)
                          ListTile(
                            dense: true,
                            leading: Icon(row.$1, size: 18, color: AppColors.brand),
                            title: Text(row.$2),
                          ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: Icon(Icons.grading, color: AppColors.brand),
                  title: const Text('Grading & scoring'),
                  subtitle: const Text(
                      'Class score / exam split and grades for each class range'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const GradingSettingsScreen())),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Classes',
                      style: TextStyle(fontSize: 15, fontWeight: .w700)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _upsertClass(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add class'),
                  ),
                ],
              ),
              for (var i = 0; i < classes.length; i++)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.brand.withValues(alpha: .1),
                      child: Text(classes[i].name.isEmpty
                          ? '?'
                          : classes[i].name.substring(0, 1)),
                    ),
                    title: Text(classes[i].displayName),
                    subtitle: Text(
                        '${roster[i]} active student(s)'
                        '${classes[i].teacherId != null ? ' · ${classes[i].teacherId}' : ''}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'edit' => _upsertClass(existing: classes[i]),
                        'delete' => _deleteClass(classes[i]),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        if (roster[i] == 0)
                          const PopupMenuItem(
                              value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteClass(ClassRoom c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete class?'),
        content: Text('Remove ${c.displayName}? Classes with students cannot be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final refused = await AdminRepository().deleteClass(c.id);
              if (refused != null) {
                if (ctx.mounted) Navigator.pop(ctx, false);
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(refused)));
                }
                return;
              }
              await AuditRepository().log(
                action: 'class.delete',
                actor: 'Admin',
                target: c.id,
                detail: c.displayName,
                reason: 'Class management',
              );
              if (ctx.mounted) Navigator.pop(ctx, true);
              _refresh();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) _refresh();
  }
}