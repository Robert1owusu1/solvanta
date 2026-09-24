import 'package:flutter/material.dart';

import 'core/models/app_notification.dart';
import 'core/models/user.dart';
import 'core/notifications/deep_link.dart';
import 'core/notifications/notifications.dart';
import 'core/settings/app_settings.dart';
import 'core/storage/local_store.dart';
import 'core/sync/sync.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/auth_repository.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/home/dashboards.dart';
import 'features/home/home_shell.dart';
import 'features/home/widgets/dashboard_scaffold.dart';
import 'features/security/security.dart';

class SolvantaApp extends StatefulWidget {
  const SolvantaApp({super.key});

  @override
  State<SolvantaApp> createState() => _SolvantaAppState();
}

class _SolvantaAppState extends State<SolvantaApp> with WidgetsBindingObserver {
  final _auth = AuthRepository();
  final _settings = AppSettings.instance;

  /// App-wide navigator so notification taps can deep-link into a module
  /// screen from outside the widget tree (background / cold start).
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Fire-and-forget: defaults render first, then persisted preferences
    // arrive and the ListenableBuilder below rebuilds with them.
    _settings.load();
    // Both self-start and are idempotent / failure-silent, so a missing
    // plugin (tests, web, desktop) can never break startup.
    ConnectivityMonitor.instance.start();
    NotificationService.instance.init();
    NotificationService.instance.configureOnNotificationOpened(_onNotificationOpened);
  }

  /// Route a tapped notification payload to its destination in-app.
  ///
  /// Payloads are notification ids (`NOTIF-*`). The kind of the tapped
  /// notification is resolved to the module the current user should land on
  /// (role-aware), and that module's own screen builder is pushed — one
  /// registry, no second router to keep in sync. Silently no-ops when the
  /// session isn't ready (app cold-starting, no logged-in user yet), which
  /// is the safe behaviour while the Inbox stays the catch-all.
  void _onNotificationOpened(String? payload) {
    if (payload == null || payload.isEmpty) return;
    _routeNotification(payload).ignore(); // fire-and-forget
  }

  Future<void> _routeNotification(String payload) async {
    final navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return;

    final user = await _auth.currentUser();
    if (user == null) return;

    AppNotification? tapped;
    for (final n in await LocalStore().loadNotifications()) {
      if (n.id == payload) {
        tapped = n;
        break;
      }
    }
    if (tapped == null) return;

    final label = notificationDestination(tapped.kind, user.role);
    Module? module;
    if (label != null) {
      for (final m in modulesFor(user.role)) {
        if (m.label == label) {
          module = m;
          break;
        }
      }
    }
    if (module?.builder == null || !navigator.mounted) return;

    await navigator.push(MaterialPageRoute(builder: module!.builder!));
    if (context.mounted) setState(() {}); // refresh the Inbox badge etc.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Only matters in ThemeMode.system, where the resolved palette changes
    // with the OS even though no preference was written.
    if (_settings.themeMode == ThemeMode.system && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // The palette globals are read by every `AppColors.*` call site during
    // descendant builds, so resolve brightness before returning the subtree.
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final settings = _settings;
        AppColors.setBrightness(settings.resolveBrightness());
        return MaterialApp(
          title: 'SOLVANTA',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themeMode,
          // Accessibility: honour the app-wide larger-text switch above
          // everything else without capping the user's OS text size.
          //
          // The app-lock cover sits *inside* the scaled MediaQuery (not
          // outside it) so the lock screen honours Larger text as well —
          // the gate is a builder-level overlay, below MaterialApp, so it
          // still sees theme, localisations and a ScaffoldMessenger.
          builder: (context, child) {
            final base = child ?? const SizedBox.shrink();
            if (!settings.largeText) return AppLockGate(child: base);
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(
                  (mq.textScaler.scale(1) * 1.25).clamp(1.0, 2.2),
                ),
              ),
              child: AppLockGate(child: base),
            );
          },
          initialRoute: '/',
          routes: {
            '/': (_) => _SessionGate(auth: _auth),
            '/login': (_) => const LoginScreen(),
            '/register': (_) => const RegisterScreen(),
            '/home': (_) => const HomeShellPage(),
          },
        );
      },
    );
  }
}

class _SessionGate extends StatelessWidget {
  const _SessionGate({required this.auth});

  final AuthRepository auth;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: auth.currentUser(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: AppTheme.brand,
                strokeWidth: 2.5,
              ),
            ),
          );
        }
        if (snap.data != null) {
          return const HomeShellPage();
        }
        return const LoginScreen();
      },
    );
  }
}
