import 'package:flutter/material.dart';

import '../../core/models/class_room.dart';
import '../../core/models/role.dart';
import '../../core/models/user.dart';
import '../../core/security/password_policy.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../audit/audit_repository.dart';
import '../auth/auth_repository.dart';
import 'admin_repository.dart';
import 'reset_password_dialog.dart';

class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  late Future<(List<User>, List<ClassRoom>)> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<(List<User>, List<ClassRoom>)> _load() async {
    final staff = await AdminRepository().staffList();
    final classes = await AdminRepository().classes();
    return (staff, classes);
  }

  void _refresh() => setState(() { _data = _load(); });

  Future<void> _upsert({User? existing}) async {
    final classes = (await _data).$2;
    if (!mounted) return;
    final name = TextEditingController(text: existing?.name ?? '');
    final email = TextEditingController(text: existing?.email ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    // Never seed this from the stored account: passwords are hashed at rest
    // now, so the stored value would be a digest (unreadable, and wrong if it
    // were saved back). Blank means "keep the current one" — see the save path.
    final password = TextEditingController();
    String? passwordError;
    AppRole role = existing?.role ?? AppRole.teacher;
    String? classId = existing?.classId;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              left: 16,
              right: 16,
              top: 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? 'Add staff member' : 'Edit staff member',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Full name')),
                const SizedBox(height: 12),
                TextField(
                    controller: email,
                    decoration: const InputDecoration(labelText: 'Email')),
                const SizedBox(height: 12),
                TextField(
                    controller: phone,
                    decoration: const InputDecoration(labelText: 'Phone')),
                const SizedBox(height: 12),
                TextField(
                    controller: password,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                        labelText: 'Password (for sign-in)',
                        errorText: passwordError,
                        helperText: existing == null
                            ? 'At least 8 characters with upper- and lower-case letters and a digit'
                            : 'Leave blank to keep the current password')),
                const SizedBox(height: 12),
                DropdownButtonFormField<AppRole>(
                  isExpanded: true,
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(
                        value: AppRole.teacher, child: Text('Teacher')),
                    DropdownMenuItem(
                        value: AppRole.headteacher,
                        child: Text('Headteacher / Principal')),
                    DropdownMenuItem(
                        value: AppRole.schoolAdmin, child: Text('School Admin')),
                    DropdownMenuItem(
                        value: AppRole.staff, child: Text('Authorized Staff')),
                  ],
                  onChanged: (v) => setSheet(() => role = v ?? AppRole.teacher),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: classId ?? '',
                  // As a bare Text above the field this hint collided with the
                  // floating 'Class' label; `helperText` sits below the input
                  // and is announced with the field by screen readers.
                  decoration: const InputDecoration(
                      labelText: 'Class',
                      helperText: 'Linked class (optional, for teachers)'),
                  items: [
                    const DropdownMenuItem(
                        value: '', child: Text('No class')),
                    for (final c in classes)
                      DropdownMenuItem(
                          value: c.id, child: Text(c.displayName)),
                  ],
                  onChanged: (v) => setSheet(() => classId = v == '' ? null : v),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: () async {
                      final pw = password.text.trim();
                      final problem = (existing != null && pw.isEmpty)
                          ? null
                          : passwordProblem(pw);
                      if (problem != null) {
                        setSheet(() => passwordError = problem);
                        return;
                      }
                      final repo = AdminRepository();
                      final users = await repo.users();
                      final me = await AuthRepository().currentUser();
                      await repo.addOrUpdateUser(User(
                        id: existing?.id ?? repo.nextUserId(users),
                        name: name.text.trim(),
                        email: email.text.trim(),
                        phone: phone.text.trim(),
                        password: pw.isEmpty ? existing!.password : pw,
                        role: role,
                        schoolId: existing?.schoolId ?? me?.schoolId ?? 'SCH-001',
                        classId: classId,
                        studentIds: existing?.studentIds ?? const [],
                      ));
                      await AuditRepository().log(
                        action: existing == null ? 'staff.add' : 'staff.update',
                        actor: 'Admin',
                        target: name.text.trim(),
                        detail: 'Role: ${role.label}',
                        reason: existing == null
                            ? 'New staff account'
                            : 'Staff details update',
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      _refresh();
                    },
                    child: Text(existing == null ? 'Add staff' : 'Save changes'),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reassignClass(User u) async {
    final classes = (await _data).$2;
    if (!mounted) return;
    String? classId = u.classId;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Assign class to ${u.name}'),
        content: DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: classId ?? '',
          items: [
            const DropdownMenuItem(value: '', child: Text('No class')),
            for (final c in classes)
              DropdownMenuItem(value: c.id, child: Text(c.displayName)),
          ],
          onChanged: (v) => classId = v == '' ? null : v,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await AdminRepository().addOrUpdateUser(User(
                id: u.id,
                name: u.name,
                email: u.email,
                phone: u.phone,
                password: u.password,
                role: u.role,
                schoolId: u.schoolId,
                classId: classId,
                studentIds: u.studentIds,
              ));
              await AuditRepository().log(
                action: 'staff.class',
                actor: 'Admin',
                target: u.name,
                detail: classId == null ? 'Class unassigned' : 'Assigned to $classId',
                reason: 'Class assignment',
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

  Future<void> _resetPassword(User u) async {
    if (await showResetPasswordDialog(context, u)) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Staff & Teachers'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _upsert(),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add staff'),
      ),
      body: FutureBuilder(
        future: _data,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final staff = snap.data?.$1 ?? const <User>[];
          if (staff.isEmpty) {
            return const Center(child: Text('No staff yet — add your first member'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: staff.length,
            itemBuilder: (context, i) {
              final u = staff[i];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppTheme.brand.withValues(alpha: .12),
                    child: Text(u.role == AppRole.teacher
                        ? 'T'
                        : u.role == AppRole.headteacher
                            ? 'H'
                            : u.role == AppRole.schoolAdmin
                                ? 'A'
                                : 'S'),
                  ),
                  title: Text(u.name),
                  subtitle: Text('${u.role.label}'
                      '${u.classId != null ? ' · ${u.classId}' : ''}'
                      '\n${u.email}${u.phone.isNotEmpty ? ' · ${u.phone}' : ''}'),
                  isThreeLine: true,
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => switch (v) {
                      'edit' => _upsert(existing: u),
                      'class' => _reassignClass(u),
                      'password' => _resetPassword(u),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit details')),
                      if (u.role == AppRole.teacher)
                        const PopupMenuItem(
                            value: 'class', child: Text('Assign class')),
                      const PopupMenuItem(
                          value: 'password', child: Text('Reset password')),
                    ],
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