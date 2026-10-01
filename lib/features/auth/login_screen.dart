import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'auth_repository.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController(text: 'efua.mensah@school.gh');
  final _password = TextEditingController(text: 'teacher123');
  var _busy = false;
  var _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final user = await AuthRepository().login(
        email: _email.text,
        password: _password.text,
      );
      if (!mounted) return;
      if (user != null) {
        Navigator.of(context).pushReplacementNamed('/home');
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
                padding: const EdgeInsets.all(28),
                child: Column(
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
                    const SizedBox(height: 40),
                    SvEntrance(
                      delay: const Duration(milliseconds: 140),
                      offset: const Offset(0, .08),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: .start,
                              children: [
                                Text('Welcome back',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: .w800,
                                        color: AppColors.ink)),
                                const SizedBox(height: 4),
                                Text('Use your school account to continue.',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: AppColors.muted)),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: _email,
                                  keyboardType: .emailAddress,
                                  autofillHints: const [AutofillHints.email],
                                  textInputAction: .next,
                                  decoration:
                                      const InputDecoration(labelText: 'Email'),
                                  validator: (v) => (v == null || !v.contains('@'))
                                      ? 'Enter a valid email'
                                      : null,
                                ),
                                const SizedBox(height: 14),
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
                                const SizedBox(height: 24),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _busy ? null : _submit,
                                    child: _busy
                                        ? const SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : const Text('Sign in'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
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
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'Demo: efua.mensah@school.gh / teacher123',
                              textAlign: .center,
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white,
                                  fontWeight: .w600),
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
        ],
      ),
    );
  }
}
