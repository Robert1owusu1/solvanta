import 'package:flutter/material.dart';

import '../../core/api/api_client.dart';
import '../../core/models/role.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../legal/legal_screen.dart';
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

  // Against a live backend the only server-supported public sign-up is the
  // independent-teacher workspace, so lock to it; offline (demo) keeps the
  // full role picker.
  final bool _configured = ApiClient.isConfigured;
  late AppRole _role = _configured ? AppRole.teacher : AppRole.parent;
  var _busy = false;
  var _obscure = true;
  late bool _independent = _configured;
  var _acceptedDataProtection = false;

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

  bool get _asIndependent => _role == AppRole.teacher && _independent;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_asIndependent && !_acceptedDataProtection) {
      svSnack(context, 'Please accept the data-protection notice to continue',
          error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final user = await AuthRepository().register(
        name: _name.text,
        email: _email.text,
        phone: _phone.text,
        password: _password.text,
        role: _role,
        independent: _asIndependent,
        acceptDataProtection: _acceptedDataProtection,
      );
      if (!mounted) return;
      if (user != null) {
        // Clear the stack: from Register the login route sits underneath, and
        // Back from the dashboard must never land a signed-in user on it.
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
      } else {
        svSnack(context, 'An account with this email exists', error: true);
      }
    } catch (e) {
      // A throw here (e.g. a failed prefs write) used to escape before
      // `_busy = false`, leaving the Create-account button permanently
      // disabled. Surface it and always release the button.
      debugPrint('[Register] failed: $e');
      if (!mounted) return;
      svSnack(context, 'Could not create the account', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
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
              // Lets the platform password manager save the new account.
              child: AutofillGroup(
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  if (_configured) ...[
                    const SvSectionTitle('Independent teacher'),
                    const SizedBox(height: 6),
                    Text(
                      'Create your own workspace to use SOLVANTA with your '
                      'class — for when your school is not on SOLVANTA yet. '
                      'School staff accounts are created by your school admin.',
                      style: TextStyle(fontSize: 13, color: AppColors.body),
                    ),
                  ] else ...[
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
                    if (_role == AppRole.teacher)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _independent,
                          onChanged: (v) => setState(() => _independent = v),
                          title:
                              const Text('My school is not on SOLVANTA yet'),
                          subtitle: Text(
                            'Set up your own independent workspace. You can '
                            'move it into your school later once it joins.',
                            style:
                                TextStyle(fontSize: 12, color: AppColors.body),
                          ),
                        ),
                      ),
                  ],
                  // The data-protection notice applies whenever an independent
                  // workspace is being created (always so against a backend).
                  if (_asIndependent)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.infoBg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Data-protection notice',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.ink)),
                          const SizedBox(height: 4),
                          Text(
                            'You will be registering children’s personal '
                            'data. Use it only for your teaching, keep it '
                            'secure, and share it with no one outside your '
                            'class. You may export or delete it at any time.',
                            style:
                                TextStyle(fontSize: 12, color: AppColors.body),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _acceptedDataProtection,
                            onChanged: (v) => setState(
                                () => _acceptedDataProtection = v ?? false),
                            title: const Text(
                                'I understand and accept this notice',
                                style: TextStyle(fontSize: 13)),
                          ),
                        ],
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
                      final t = v?.trim() ?? '';
                      if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t)) {
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
                      helperText: _configured
                          ? 'At least 8 characters, with a capital letter and a number'
                          : 'At least 6 characters',
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
                    validator: (v) {
                      final t = v ?? '';
                      if (!_configured) {
                        return t.length < 6 ? 'At least 6 characters' : null;
                      }
                      // Match the server policy for live-backend sign-up.
                      if (t.length < 8) return 'At least 8 characters';
                      if (!RegExp(r'[a-z]').hasMatch(t) ||
                          !RegExp(r'[A-Z]').hasMatch(t) ||
                          !RegExp(r'\d').hasMatch(t)) {
                        return 'Add a capital letter and a number';
                      }
                      return null;
                    },
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
                  const SizedBox(height: 4),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('By creating an account you agree to our ',
                          style:
                              TextStyle(fontSize: 12, color: AppColors.muted)),
                      TextButton(
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 0),
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const LegalScreen(doc: LegalDoc.terms))),
                        child: const Text('Terms',
                            style: TextStyle(fontSize: 12)),
                      ),
                      Text(' and ',
                          style:
                              TextStyle(fontSize: 12, color: AppColors.muted)),
                      TextButton(
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 0),
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const LegalScreen(
                                    doc: LegalDoc.privacy))),
                        child: const Text('Privacy Policy',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
