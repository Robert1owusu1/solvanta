import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/api/remote_data_source.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Self-service password reset: request a code by email, then set a new password
/// with it. Server-backed, so it needs an API endpoint configured.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _remote = RemoteDataSource();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_email.text.trim().isEmpty) {
      svSnack(context, 'Enter your email', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _remote.forgotPassword(_email.text.trim());
      if (mounted) setState(() => _sent = true);
    } on ApiException catch (e) {
      if (mounted) svSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (_code.text.trim().isEmpty || _password.text.length < 8) {
      svSnack(context, 'Enter the code and a password of at least 8 characters',
          error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _remote.resetPassword(_code.text.trim(), _password.text);
      if (!mounted) return;
      svSnack(context, 'Password changed. Please sign in.');
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) svSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
          title: 'Reset password', subtitle: 'We’ll email you a code'),
      body: !ApiClient.isConfigured
          ? const SvEmptyState(
              icon: Icons.cloud_off,
              title: 'Server required',
              message:
                  'Password reset needs a connection. Ask your school admin to '
                  'reset it if you are offline.')
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              children: [
                TextField(
                  controller: _email,
                  enabled: !_sent,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                if (!_sent)
                  FilledButton(
                    onPressed: _busy ? null : _send,
                    child: Text(_busy ? 'Sending…' : 'Send reset code'),
                  )
                else ...[
                  Text(
                    'If that email is registered, a reset code is on its way. '
                    'Paste it below with your new password.',
                    style: TextStyle(fontSize: 13, color: AppColors.body),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _code,
                    decoration: const InputDecoration(labelText: 'Reset code'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'New password',
                        helperText: 'At least 8 characters'),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy ? null : _reset,
                    child: Text(_busy ? 'Saving…' : 'Set new password'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : _send,
                    child: const Text('Resend code'),
                  ),
                ],
              ],
            ),
    );
  }
}
