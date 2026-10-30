import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';

/// Texts to parents: which events the school sends (everything is off until
/// the admin turns it on — texts cost money), fee reminders on demand, and
/// the log of what went out. Talks to the server directly.
class SmsScreen extends StatefulWidget {
  const SmsScreen({super.key, this.client});

  /// For tests; the app's own client otherwise.
  final ApiClient? client;

  @override
  State<SmsScreen> createState() => _SmsScreenState();
}

class _SmsData {
  _SmsData(this.settings, this.provider, this.log, this.canEdit,
      {this.senderId = '', this.usage = const {}});

  final Map<String, bool> settings;
  final String senderId;

  /// This month's texts by outcome: month, sent, failed, logged.
  final Map<String, dynamic> usage;
  final String provider;
  final List<Map<String, dynamic>> log;
  final bool canEdit;
}

class _SmsScreenState extends State<SmsScreen> {
  static const _events = [
    ('reportCards', 'Report card ready', 'When the headteacher approves it'),
    ('absences', 'Absence', 'When a pupil is marked absent'),
    ('meetings', 'Meeting booked', 'When a parent meeting is scheduled'),
    ('feeReminders', 'Fee reminders', 'Only when you send them below'),
  ];

  /// Loads only with a server to ask (never, offline).
  late Future<_SmsData> _data = _online ? _load() : Completer<_SmsData>().future;
  bool _busy = false;

  ApiClient get _api => widget.client ?? ApiClient();

  bool get _online => widget.client != null || ApiClient.isConfigured;

  Future<_SmsData> _load() async {
    final res = await _api.get('/api/sms/settings') as Map<String, dynamic>;
    final log = await _api.get('/api/sms/log') as List;
    final me = await AuthRepository().currentUser();
    final raw = (res['settings'] ?? const {}) as Map<String, dynamic>;
    return _SmsData(
      {
        for (final e in raw.entries)
          if (e.value is bool) e.key: e.value as bool,
      },
      (res['provider'] ?? 'log') as String,
      log.cast<Map<String, dynamic>>(),
      widget.client != null || (me?.role.canManageGrading ?? false),
      senderId: (raw['senderId'] ?? '') as String,
      usage: (res['usage'] ?? const {}) as Map<String, dynamic>,
    );
  }

  Future<void> _set(_SmsData d, String key, bool value) async {
    setState(() => _busy = true);
    try {
      await _api.request('PUT', '/api/sms/settings',
          body: {...d.settings, 'senderId': d.senderId, key: value},
          offlineQueue: false);
      setState(() {
        _data = _load();
      });
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editSender(_SmsData d) async {
    final c = TextEditingController(text: d.senderId);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sender name'),
        content: TextField(
          controller: c,
          maxLength: 11,
          decoration: const InputDecoration(
            helperText: 'What parents see as the sender: 3–11 letters or '
                'digits, registered with your SMS provider',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    if (name == null) return;
    setState(() => _busy = true);
    try {
      await _api.request('PUT', '/api/sms/settings',
          body: {...d.settings, 'senderId': name}, offlineQueue: false);
      setState(() {
        _data = _load();
      });
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _feeReminders() async {
    final ok = await svConfirm(context,
        title: 'Send fee reminders?',
        message: 'Every family with fees outstanding gets a text with the '
            'amount. Each text is charged by your SMS provider.',
        confirmLabel: 'Send');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final res = await _api.request('POST', '/api/sms/fee-reminders',
          offlineQueue: false) as Map<String, dynamic>;
      _snack('Sent ${res['texts']} text(s) to ${res['families']} families.');
      setState(() {
        _data = _load();
      });
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final online = _online;
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'SMS to Parents',
        subtitle: 'Texts for families without the app',
      ),
      body: !online
          ? const SvEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Needs the school server',
              message: 'Texts are sent by the server. Connect this app to it '
                  'to manage SMS.',
            )
          : FutureBuilder<_SmsData>(
              future: _data,
              builder: (context, snap) {
                if (snap.hasError) {
                  return SvErrorState(
                    title: "Couldn't load SMS settings",
                    onRetry: () => setState(() {
                      _data = _load();
                    }),
                  );
                }
                final d = snap.data;
                if (d == null) return const SvListSkeleton();
                final on = d.settings['enabled'] ?? false;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Card(
                      child: ListTile(
                        leading: Icon(
                          d.provider == 'log'
                              ? Icons.info_outline
                              : Icons.sms_outlined,
                          color: AppColors.brand,
                        ),
                        title: Text(d.provider == 'log'
                            ? 'No SMS provider connected'
                            : 'Sending through ${d.provider}'),
                        subtitle: Text(d.provider == 'log'
                            ? 'Texts are only logged until the server is '
                                'given an Arkesel or Hubtel account.'
                            : 'Each text is charged by the provider.'),
                      ),
                    ),
                    ListTile(
                      leading:
                          Icon(Icons.badge_outlined, color: AppColors.brand),
                      title: Text(d.senderId.isEmpty
                          ? "Sender name: the platform's"
                          : 'Sender name: ${d.senderId}'),
                      subtitle: Text('This month (${d.usage['month'] ?? ''}): '
                          '${d.usage['sent'] ?? 0} sent · '
                          '${d.usage['failed'] ?? 0} failed'
                          '${(d.usage['logged'] ?? 0) == 0 ? '' : ' · ${d.usage['logged']} logged only'}'),
                      trailing:
                          d.canEdit ? const Icon(Icons.edit_outlined) : null,
                      onTap: d.canEdit && !_busy ? () => _editSender(d) : null,
                    ),
                    SwitchListTile(
                      title: const Text('Text parents',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: const Text('Master switch for every event'),
                      value: on,
                      onChanged: !d.canEdit || _busy
                          ? null
                          : (v) => _set(d, 'enabled', v),
                    ),
                    for (final (key, title, help) in _events)
                      SwitchListTile(
                        title: Text(title),
                        subtitle: Text(help),
                        value: d.settings[key] ?? false,
                        onChanged: !d.canEdit || _busy || !on
                            ? null
                            : (v) => _set(d, key, v),
                      ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ||
                              !on ||
                              !(d.settings['feeReminders'] ?? false)
                          ? null
                          : _feeReminders,
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Send fee reminders now'),
                    ),
                    const SvSectionTitle('Recent texts'),
                    if (d.log.isEmpty)
                      Text('Nothing sent yet.',
                          style: TextStyle(color: AppColors.muted)),
                    for (final e in d.log.take(50))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          switch (e['status']) {
                            'sent' => Icons.check_circle_outline,
                            'failed' => Icons.error_outline,
                            _ => Icons.notes,
                          },
                          color: e['status'] == 'failed'
                              ? AppColors.danger
                              : AppColors.brand,
                        ),
                        title: Text('${e['text']}',
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text([
                          '${e['to']}',
                          '${e['status']}',
                          '${e['at']}',
                          if ((e['error'] ?? '') != '') '${e['error']}',
                        ].join(' · ')),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
