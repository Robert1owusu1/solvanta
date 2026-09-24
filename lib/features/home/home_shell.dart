import 'package:flutter/material.dart';

import '../../core/models/user.dart';
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

  Future<void> _logout() async {
    await _auth.logout();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: _auth.currentUser(),
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