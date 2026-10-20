import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/responsive.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import 'auth_repository.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

/// Seeded offline accounts, one per role, offered as tap-to-fill chips so a
/// demo never needs credentials read off a slide.
const _demoAccounts = <(String, String, String)>[
  ('Teacher', 'efua.mensah@school.gh', 'teacher123'),
  ('Headteacher', 'head@school.gh', 'head123'),
  ('School admin', 'admin@solvanta.app', 'admin123'),
  ('Parent', 'ama.owusu@school.gh', 'parent123'),
  ('Student', 'kojo.owusu@school.gh', 'student123'),
];

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  // Debug builds (and tests) start prefilled with the teacher account; a
  // release build never ships a password sitting in the field.
  final _email =
      TextEditingController(text: kDebugMode ? _demoAccounts.first.$2 : '');
  final _password =
      TextEditingController(text: kDebugMode ? _demoAccounts.first.$3 : '');
  var _busy = false;
  var _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _useDemo((String, String, String) account) {
    svHaptic(SvHaptic.light);
    _email.text = account.$2;
    _password.text = account.$3;
    _formKey.currentState?.validate();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final user = await AuthRepository().login(
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      if (user != null) {
        // Clear the stack so Back from the dashboard never lands a signed-in
        // user on the sign-in form.
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
      } else {
        svSnack(context, 'Invalid email or password', error: true);
      }
    } on ApiException catch (e) {
      // In API mode AuthRepository.login rethrows ApiExceptions (401 for a bad
      // password, statusCode 0 when the backend is unreachable). Without this
      // catch the await never reaches `_busy = false`, so one failed attempt
      // left the sign-in button disabled forever.
      if (!mounted) return;
      svSnack(
        context,
        e.isNetwork ? 'Cannot reach the server' : e.message,
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dc = context.deviceClass;
    final isDesktop = dc == DeviceClass.desktop || dc == DeviceClass.largeDesktop;
    final isTablet = dc == DeviceClass.tablet || dc == DeviceClass.largeTablet;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Navy ramp background — gold stays out of the full-bleed fill so
          // it remains the ~10% accent (see brand rules).
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: .topLeft,
                end: .bottomRight,
                colors: [AppTheme.navy900, AppTheme.navy700],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: isDesktop
                    ? const EdgeInsets.symmetric(horizontal: 48, vertical: 32)
                    : isTablet
                        ? const EdgeInsets.symmetric(horizontal: 32, vertical: 28)
                        : const EdgeInsets.all(24),
                child: ResponsivePage(
                  maxWidth: isDesktop ? 440 : (isTablet ? 400 : double.infinity),
                  centered: !isTablet, // On tablet, let it be slightly wider
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvEntrance(
                        offset: const Offset(0, .06),
                        duration: const Duration(milliseconds: 520),
                        child: Column(
                          children: [
                            Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .14),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: const Icon(Icons.auto_awesome,
                                  size: 38, color: AppTheme.gold),
                            ),
                            const SizedBox(height: 18),
                            const Text('SOLVANTA',
                                style: TextStyle(
                                    fontSize: 32,
                                    fontWeight: .w800,
                                    letterSpacing: 6,
                                    color: Colors.white)),
                            const SizedBox(height: 8),
                            const Text('Intelligence that illuminates possibility.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white70)),
                            const SizedBox(height: 6),
                            // Gold accent hairline under the wordmark.
                            Container(
                              height: 3,
                              width: 54,
                              decoration: BoxDecoration(
                                color: AppTheme.gold,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: isDesktop ? 48 : 40),
                      SvEntrance(
                        delay: const Duration(milliseconds: 140),
                        offset: const Offset(0, .08),
                        child: ResponsiveCard(
                          phonePadding: 22,
                          tabletPadding: 28,
                          desktopPadding: 32,
                          child: Form(
                            key: _formKey,
                            // Lets the platform password manager offer and
                            // save credentials for the email/password pair.
                            child: AutofillGroup(
                            child: Column(
                              crossAxisAlignment: .start,
                              children: [
                                Text('Welcome back',
                                    style: TextStyle(
                                        fontSize: isDesktop ? 20 : 17,
                                        fontWeight: .w800,
                                        color: AppColors.ink)),
                                const SizedBox(height: 4),
                                Text('Use your school account to continue.',
                                    style: TextStyle(
                                        fontSize: isDesktop ? 14 : 12.5,
                                        color: AppColors.muted)),
                                const SizedBox(height: 24),
                                TextFormField(
                                  controller: _email,
                                  keyboardType: .emailAddress,
                                  autofillHints: const [AutofillHints.email],
                                  textInputAction: .next,
                                  decoration:
                                      const InputDecoration(labelText: 'Email'),
                                  validator: (v) {
                                    final t = v?.trim() ?? '';
                                    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                            .hasMatch(t)
                                        ? null
                                        : 'Enter a valid email';
                                  },
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _password,
                                  obscureText: _obscure,
                                  autofillHints: const [
                                    AutofillHints.password
                                  ],
                                  textInputAction: .done,
                                  onFieldSubmitted: (_) => _submit(),
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    suffixIcon: IconButton(
                                      tooltip: _obscure
                                          ? 'Show password'
                                          : 'Hide password',
                                      icon: Icon(
                                        _obscure
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        color: AppColors.muted,
                                      ),
                                      onPressed: () =>
                                          setState(() => _obscure = !_obscure),
                                    ),
                                  ),
                                  validator: (v) => (v == null || v.isEmpty)
                                      ? 'Required'
                                      : null,
                                ),
                                const SizedBox(height: 28),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _busy ? null : _submit,
                                    style: FilledButton.styleFrom(
                                      padding: EdgeInsets.symmetric(vertical: isDesktop ? 18 : 16),
                                    ),
                                    child: _busy
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : Text('Sign in', style: TextStyle(fontSize: isDesktop ? 16 : 15)),
                                  ),
                                ),
                              ],
                            ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SvEntrance(
                        delay: const Duration(milliseconds: 300),
                        child: Column(
                          children: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(context).pushNamed('/register'),
                              child: const Text('Create an account',
                                  style: TextStyle(color: Colors.white)),
                            ),
                            const SizedBox(height: 12),
                            Text('Try a demo account',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: .w700,
                                    letterSpacing: .3,
                                    color: Colors.white.withValues(alpha: .75))),
                            const SizedBox(height: 10),
                            // Rebuild on typing so the highlighted chip always
                            // matches the email actually in the field.
                            ListenableBuilder(
                              listenable: _email,
                              // A chip's Material is canvas-typed, so it paints
                              // theme.canvasColor (opaque white) under its own
                              // translucent fill; on the navy ramp that hid the
                              // white labels. Clear the canvas for this row.
                              builder: (context, _) => Theme(
                                data: Theme.of(context)
                                    .copyWith(canvasColor: Colors.transparent),
                                child: Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final a in _demoAccounts)
                                      ActionChip(
                                        label: Text(a.$1),
                                        tooltip: 'Fill in ${a.$2}',
                                        onPressed: _busy ? null : () => _useDemo(a),
                                        labelStyle: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: .w700,
                                          color: _email.text == a.$2
                                              ? AppTheme.navy900
                                              : Colors.white,
                                        ),
                                        backgroundColor: _email.text == a.$2
                                            ? AppTheme.gold
                                            : Colors.white.withValues(alpha: .12),
                                        side: BorderSide(
                                            color:
                                                Colors.white.withValues(alpha: .22)),
                                        shape: const StadiumBorder(),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
