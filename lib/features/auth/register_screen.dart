import 'package:flutter/material.dart';

import '../../core/models/role.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import 'auth_repository.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  AppRole _role = AppRole.parent;
  var _busy = false;
  var _obscure = true;

  static const _selfRoles = [
    AppRole.teacher,
    AppRole.parent,
    AppRole.student,
  ];

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final user = await AuthRepository().register(
      name: _name.text,
      email: _email.text,
      phone: _phone.text,
      password: _password.text,
      role: _role,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (user != null) {
      Navigator.of(context).pushReplacementNamed('/home');
    } else {
      svSnack(context, 'An account with this email exists', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SvScreenHeader(
        title: 'Create your account',
        subtitle: 'Join your school on SOLVANTA',
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: SvEntrance(
            offset: const Offset(0, .04),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  const SvSectionTitle('Who are you?'),
                  const SizedBox(height: 4),
                  // Segmented role picker — kinder than a dropdown for three
                  // fixed options, and one fewer tap on mobile.
                  SegmentedButton<AppRole>(
                    segments: [
                      for (final r in _selfRoles)
                        ButtonSegment(
                          value: r,
                          label: Text(
                            r.label.split(' ').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    selected: {_role},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) =>
                        setState(() => _role = s.first),
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? AppTheme.brand
                            : AppColors.surface,
                      ),
                      foregroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? Colors.white
                            : AppColors.ink,
                      ),
                      textStyle: WidgetStateProperty.all(
                        const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      side: WidgetStateProperty.all(
                        BorderSide(color: AppColors.border),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _name,
                    textCapitalization: .words,
                    autofillHints: const [AutofillHints.name],
                    textInputAction: .next,
                    decoration: const InputDecoration(labelText: 'Full name'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _email,
                    keyboardType: .emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: .next,
                    decoration: const InputDecoration(labelText: 'Email'),
                    validator: (v) {
                      if (v == null || !v.contains('@')) {
                        return 'Enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _phone,
                    keyboardType: .phone,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    textInputAction: .next,
                    decoration: const InputDecoration(labelText: 'Phone'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Required'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: .done,
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: 'At least 6 characters',
                      suffixIcon: IconButton(
                        tooltip:
                            _obscure ? 'Show password' : 'Hide password',
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
                    validator: (v) => (v == null || v.length < 6)
                        ? 'At least 6 characters'
                        : null,
                  ),
                  const SizedBox(height: 26),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Create account'),
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('I already have an account'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
