import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/api/api_client.dart';
import '../../core/api/remote_data_source.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Two-factor (TOTP) enrolment: scan the QR with an authenticator app, enter a
/// code to turn it on, and turn it off with a current code. Server-backed, so
/// it needs an API endpoint configured.
class MfaSettingsScreen extends StatefulWidget {
  const MfaSettingsScreen({super.key});

  @override
  State<MfaSettingsScreen> createState() => _MfaSettingsScreenState();
}

class _MfaSettingsScreenState extends State<MfaSettingsScreen> {
  final _remote = RemoteDataSource();
  final _code = TextEditingController();
  late Future<bool> _enabled = _load();
  ({String secret, String uri})? _setup; // non-null while enrolling
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<bool> _load() => _remote.mfaEnabled();
  void _reload() => setState(() {
        _setup = null;
        _code.clear();
        _enabled = _load();
      });

  void _snack(String m, {bool error = false}) {
    if (mounted) svSnack(context, m, error: error);
  }

  Future<void> _beginSetup() async {
    setState(() => _busy = true);
    try {
      final s = await _remote.mfaSetup();
      if (mounted) setState(() => _setup = s);
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    try {
      await _remote.mfaEnable(_code.text.trim());
      _snack('Two-factor is on.');
      _reload();
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    final code = await _promptCode('Turn off two-factor');
    if (code == null || code.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _remote.mfaDisable(code);
      _snack('Two-factor is off.');
      _reload();
    } on ApiException catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptCode(String title) async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '6-digit code'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
              child: const Text('Confirm')),
        ],
      ),
    );
    c.dispose();
    return v;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(
          title: 'Two-factor authentication',
          subtitle: 'An extra step at sign-in'),
      body: !ApiClient.isConfigured
          ? const SvEmptyState(
              icon: Icons.cloud_off,
              title: 'Server required',
              message: 'Two-factor is managed on the server.')
          : FutureBuilder<bool>(
              future: _enabled,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SvListSkeleton();
                }
                if (snap.hasError) {
                  return SvErrorState(
                      message: 'Could not load your security settings',
                      onRetry: _reload);
                }
                final on = snap.data ?? false;
                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: on ? _onView() : _offView(),
                );
              },
            ),
    );
  }

  List<Widget> _onView() => [
        Row(children: [
          Icon(Icons.verified_user, color: AppColors.success),
          const SizedBox(width: 10),
          const Expanded(
              child: Text('Two-factor is on. You’ll enter a code from your '
                  'authenticator app each time you sign in.')),
        ]),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _busy ? null : _disable,
          icon: Icon(Icons.gpp_bad_outlined, color: AppColors.danger),
          label: Text('Turn off', style: TextStyle(color: AppColors.danger)),
        ),
      ];

  List<Widget> _offView() {
    final setup = _setup;
    if (setup == null) {
      return [
        const Text(
            'Protect your account with a one-time code from an authenticator '
            'app (Google Authenticator, Authy, …) in addition to your password.'),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : _beginSetup,
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Set up two-factor'),
        ),
      ];
    }
    return [
      const Text('1 · Scan this with your authenticator app'),
      const SizedBox(height: 12),
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          color: Colors.white,
          child: QrImageView(data: setup.uri, size: 200),
        ),
      ),
      const SizedBox(height: 10),
      SelectableText('Or enter this key manually:\n${setup.secret}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 20),
      const Text('2 · Enter the 6-digit code it shows'),
      const SizedBox(height: 8),
      TextField(
        controller: _code,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: const InputDecoration(labelText: '6-digit code'),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _enable,
        child: Text(_busy ? 'Enabling…' : 'Turn on two-factor'),
      ),
    ];
  }
}
