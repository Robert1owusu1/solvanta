import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import 'dashboards.dart';
import 'widgets/dashboard_scaffold.dart';

class HomeShellPage extends StatefulWidget {
  const HomeShellPage({super.key});

  @override
  State<HomeShellPage> createState() => _HomeShellPageState();
}

class _HomeShellPageState extends State<HomeShellPage> {
  final _auth = AuthRepository();

  /// Resolved once: rebuilding the shell (theme switch, larger text) must not
  /// re-run the session lookup and flash a full-screen spinner.
  late final Future<User?> _user = _auth.currentUser();

  Future<void> _logout() async {
    // The header icon sits next to Search/Settings; one stray tap shouldn't
    // end the session (and, offline, strand unsynced work behind a login).
    final ok = await svConfirm(
      context,
      title: 'Sign out?',
      message: 'You will need your email and password to sign back in.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _auth.logout();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: _user,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final User? user = snap.data;
        if (user == null) {
          return Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).pushReplacementNamed('/'),
                child: const Text('Back to sign in'),
              ),
            ),
          );
        }
        return AuthLogout(
          onLogout: _logout,
          child: dashboardFor(user),
        );
      },
    );
  }
}