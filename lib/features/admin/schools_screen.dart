import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/school.dart';
import '../../core/platform/file_share.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// The platform's schools (super admin only): each has its own store on the
/// server. Onboarding a school creates it and its first school admin, who
/// then sets up the term, classes, staff and grading themselves.
///
/// Talks to the server directly — never queued — since a school that only
/// exists on this device would be no school at all.
class SchoolsScreen extends StatefulWidget {
  const SchoolsScreen({super.key, this.client});

  /// For tests; the app's own client otherwise.
  final ApiClient? client;

  @override
  State<SchoolsScreen> createState() => _SchoolsScreenState();
}

class _SchoolsScreenState extends State<SchoolsScreen> {
  /// Loads only with a server to ask (never, offline).
  late Future<List<School>> _schools =
      _online ? _load() : Completer<List<School>>().future;

  ApiClient get _api => widget.client ?? ApiClient();

  bool get _online => widget.client != null || ApiClient.isConfigured;

final Set<String> _suspended = {};

  Future<List<School>> _load() async {
    final rows =
        (await _api.get('/api/schools') as List).cast<Map<String, dynamic>>();
    _suspended
      ..clear()
      ..addAll([
        for (final r in rows)
          if (r['suspended'] == true) r['id'] as String,
      ]);
    return [for (final r in rows) School.fromJson(r)]
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  void _reload() => setState(() {
        _schools = _load();
      });

  Future<void> _call(String method, String path, String done) async {
    try {
      await _api.request(method, path, offlineQueue: false);
      _snack(done);
      _reload();
    } on ApiException catch (e) {
      _snack(e.isNetwork ? "Couldn't reach the school server." : e.message);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _edit(School s) async {
    final name = TextEditingController(text: s.name);
    final region = TextEditingController(text: s.region);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${s.id}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'School name')),
          TextField(
              controller: region,
              decoration: const InputDecoration(labelText: 'Region')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    final body = {
      ...s.toJson(),
      'name': name.text.trim(),
      'region': region.text.trim(),
    };
    name.dispose();
    region.dispose();
    if (ok != true) return;
    try {
      await _api.request('PUT', '/api/schools/${s.id}',
          body: body, offlineQueue: false);
      _reload();
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _export(School s) async {
    try {
      final data = await _api.get('/api/schools/${s.id}/export');
      await saveAndShareFile(
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
        '${s.id}-export.json',
        'application/json',
      );
    } on ApiException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _delete(School s) async {
    final typed = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${s.name}?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Every student, mark, payment and account of this school '
              'is removed for good. Export it first if it may be needed.'),
          const SizedBox(height: 12),
          TextField(
            controller: typed,
            decoration: InputDecoration(labelText: 'Type ${s.id} to confirm'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, typed.text.trim() == s.id),
            child: const Text('Delete for good'),
          ),
        ],
      ),
    );
    typed.dispose();
    if (ok == true) {
      await _call('DELETE', '/api/schools/${s.id}?confirm=${s.id}',
          '${s.name} was deleted.');
    }
  }

  /// What the platform owner can do with a school.
  Future<void> _actions(School s) async {
    final suspended = _suspended.contains(s.id);
    final platform = s.id == 'SCH-001';
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(s.name), subtitle: Text(s.id)),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit name and region'),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export all data (JSON)'),
            onTap: () => Navigator.pop(ctx, 'export'),
          ),
          if (!platform)
            ListTile(
              leading:
                  Icon(suspended ? Icons.play_circle_outline : Icons.block),
              title: Text(suspended ? 'Reactivate' : 'Suspend access'),
              subtitle: Text(suspended
                  ? 'Its staff and families can sign in again'
                  : 'Everyone in it is signed out; data is kept'),
              onTap: () =>
                  Navigator.pop(ctx, suspended ? 'activate' : 'suspend'),
            ),
          if (!platform && suspended)
            ListTile(
              leading: Icon(Icons.delete_forever, color: AppColors.danger),
              title: const Text('Delete school'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'edit':
        await _edit(s);
      case 'export':
        await _export(s);
      case 'suspend':
        if (await svConfirm(context,
            title: 'Suspend ${s.name}?',
            message: "Its staff and families are signed out and can't sign "
                'in until you reactivate it. Nothing is deleted.',
            confirmLabel: 'Suspend',
            destructive: true)) {
          await _call('POST', '/api/schools/${s.id}/suspend',
              '${s.name} is suspended.');
        }
      case 'activate':
        await _call('POST', '/api/schools/${s.id}/activate',
            '${s.name} is active again.');
      case 'delete':
        await _delete(s);
    }
  }

  Future<void> _onboard() async {
    final created = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OnboardSheet(api: _api),
    );
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$created is ready. Its admin can now sign in.')),
    );
    setState(() {
      _schools = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final online = _online;
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'Schools',
        subtitle: 'Onboard schools and their first admin',
      ),
      floatingActionButton: online
          ? FloatingActionButton.extended(
              onPressed: _onboard,
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('Add school'),
            )
          : null,
      body: !online
          ? const SvEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Needs the school server',
              message:
                  'Schools are created on the server. Connect this app '
                  'to it (config.json) to onboard a school.',
            )
          : FutureBuilder<List<School>>(
              future: _schools,
              builder: (context, snap) {
                if (snap.hasError) {
                  return SvErrorState(
                    title: "Couldn't load schools",
                    onRetry: () => setState(() {
                      _schools = _load();
                    }),
                  );
                }
                final schools = snap.data;
                if (schools == null) return const SvListSkeleton();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    for (final s in schools)
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppTheme.brand.withValues(
                              alpha: .12,
                            ),
                            child: Icon(
                              Icons.school_outlined,
                              color: AppColors.brand,
                            ),
                          ),
                          title: Text(s.name.isEmpty ? s.id : s.name),
                          subtitle: Text(
                            [
                              s.id,
                              if (s.region.isNotEmpty) s.region,
                              if (_suspended.contains(s.id)) 'Suspended',
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.more_vert),
                          onTap: () => _actions(s),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _OnboardSheet extends StatefulWidget {
  const _OnboardSheet({required this.api});

  final ApiClient api;

  @override
  State<_OnboardSheet> createState() => _OnboardSheetState();
}

class _OnboardSheetState extends State<_OnboardSheet> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _region = TextEditingController();
  final _adminName = TextEditingController();
  final _adminEmail = TextEditingController();
  final _adminPassword = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _id,
      _name,
      _region,
      _adminName,
      _adminEmail,
      _adminPassword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final id = _id.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9_-]{1,40}$').hasMatch(id) ||
        _name.text.trim().isEmpty ||
        _adminName.text.trim().isEmpty ||
        _adminEmail.text.trim().isEmpty ||
        _adminPassword.text.isEmpty) {
      setState(
        () => _error =
            'Fill in every field. The school code may use '
            'letters, digits, - and _ (e.g. SCH-002).',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.request(
        'POST',
        '/api/schools',
        body: {
          'id': id,
          'name': _name.text.trim(),
          'region': _region.text.trim(),
        },
        offlineQueue: false,
      );
      await widget.api.request(
        'POST',
        '/api/users',
        body: {
          'name': _adminName.text.trim(),
          'email': _adminEmail.text.trim(),
          'password': _adminPassword.text,
          'role': 'schoolAdmin',
          'schoolId': id,
        },
        offlineQueue: false,
      );
      if (mounted) Navigator.of(context).pop(_name.text.trim());
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.isNetwork
            ? "Couldn't reach the school server. Try again when online."
            : e.message;
      });
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = false,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Add a school',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _field(_id, 'School code (e.g. SCH-002)'),
            _field(_name, 'School name'),
            _field(_region, 'Region (optional)'),
            const SizedBox(height: 4),
            const Text(
              'First school admin',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _field(_adminName, 'Full name'),
            _field(
              _adminEmail,
              'Email (their sign-in)',
              keyboard: TextInputType.emailAddress,
            ),
            _field(_adminPassword, 'Temporary password', obscure: true),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!, style: TextStyle(color: AppColors.danger)),
              ),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Creating…' : 'Create school'),
            ),
          ],
        ),
      ),
    );
  }
}
