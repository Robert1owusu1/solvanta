import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/security/password_policy.dart';
import '../../core/ui/ui_kit.dart';
import '../audit/audit_repository.dart';
import 'admin_repository.dart';

/// Lets an administrator set a new password for someone who has forgotten
/// theirs. The server signs the account out of its other devices. Returns
/// whether a password was set.
Future<bool> showResetPasswordDialog(BuildContext context, User u) async {
  final password = TextEditingController();
  String? error;
  final done = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) => AlertDialog(
        title: Text('Reset password for ${u.name}'),
        content: TextField(
          controller: password,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'New password',
            helperText:
                '8+ characters with upper- and lower-case letters and a digit',
            helperMaxLines: 2,
            errorText: error,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final pw = password.text.trim();
              final problem = passwordProblem(pw);
              if (problem != null) {
                setDialog(() => error = problem);
                return;
              }
              await AdminRepository().addOrUpdateUser(User(
                id: u.id,
                name: u.name,
                email: u.email,
                phone: u.phone,
                password: pw,
                role: u.role,
                schoolId: u.schoolId,
                classId: u.classId,
                studentIds: u.studentIds,
              ));
              await AuditRepository().log(
                action: 'user.password_reset',
                actor: 'Admin',
                target: u.name,
                detail: 'Password reset',
                reason: 'Forgotten password',
              );
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    ),
  );
  if (done == true && context.mounted) {
    svSnack(context, 'Password reset for ${u.name}');
  }
  return done == true;
}
