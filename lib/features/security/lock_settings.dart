import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// Set, change or remove the app-lock PIN — the piece the existing Settings
/// screen is missing (it only toggles the lock and picks the method).
///
/// ## Where to insert (lead's wiring, `lib/features/settings/settings_screen.dart`)
///
/// Add the import:
///
/// ```dart
/// import '../security/security.dart';
/// ```
///
/// …then drop this one line into the `ListView.children`, immediately after
/// the `if (s.lockEnabled) _Card(…)` unlock-method block and before
/// `const SvSectionTitle('Accessibility'),`:
///
/// ```dart
/// const LockSettingsSection(),
/// ```
///
/// The section hides itself while App lock is off, so no `if` is needed.
///
/// ## PIN storage note
///
/// The PIN is written through `AppSettings.setLockPin`, which stores a salted,
/// stretched hash (`v2$salt$iterations$digest`) — the plain digits never reach
/// `shared_prefs`. An install written by an older build still holds the plain
/// value; `AppSettings.load` verifies it once and rewrites it hashed, so no
/// migration step is needed at this call site. This front-end lock is
/// device-convenience, not a security boundary.
class LockSettingsSection extends StatefulWidget {
  const LockSettingsSection({super.key});

  @override
  State<LockSettingsSection> createState() => _LockSettingsSectionState();
}

class _LockSettingsSectionState extends State<LockSettingsSection> {
  final _settings = AppSettings.instance;
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _editing = false;
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  bool get _hasPin => _settings.hasLockPin;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        // Self-contained: invisible until the user turns App lock on.
        if (!_settings.lockEnabled) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SvSectionTitle('App lock PIN'),
            _PinCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _hasPin
                          ? SvStatusBadge(
                              label: 'PIN set',
                              icon: Icons.check_circle,
                              color: AppColors.success,
                            )
                          : SvStatusBadge(
                              label: 'No PIN yet',
                              icon: Icons.info_outline,
                              color: AppColors.info,
                            ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'A 4–6 digit PIN unlocks the app when biometrics '
                          'aren’t available.',
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.4,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (!_editing) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!_hasPin)
                          FilledButton.icon(
                            onPressed: _startEditing,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Set PIN'),
                          )
                        else ...[
                          OutlinedButton.icon(
                            onPressed: _startEditing,
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Change PIN'),
                          ),
                          TextButton(
                            onPressed: _confirmRemove,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.danger,
                            ),
                            child: const Text('Remove'),
                          ),
                        ],
                      ],
                    ),
                  ] else
                    _form(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _startEditing() {
    svHaptic(SvHaptic.selection);
    _pinController.clear();
    _confirmController.clear();
    setState(() {
      _editing = true;
      _error = null;
    });
  }

  void _cancelEditing() {
    svHaptic(SvHaptic.selection);
    _pinController.clear();
    _confirmController.clear();
    setState(() {
      _editing = false;
      _error = null;
    });
  }

  void _save() {
    // The formatter only admits digits, so length is the real validation.
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();
    final String? error;
    if (pin.length < 4 || pin.length > 6) {
      error = 'Choose a PIN with 4 to 6 digits.';
    } else if (pin != confirm) {
      error = 'The two PINs don’t match — try again.';
    } else {
      error = null;
    }
    if (error != null) {
      svHaptic(SvHaptic.error);
      setState(() => _error = error);
      return;
    }
    svHaptic(SvHaptic.medium);
    // Hashed at rest by setLockPin — see the class docs (PIN storage note).
    _settings.setLockPin(pin);
    _pinController.clear();
    _confirmController.clear();
    setState(() {
      _editing = false;
      _error = null;
    });
    svSnack(context, 'App-lock PIN saved');
  }

  Future<void> _confirmRemove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove PIN?'),
        content: const Text(
          'The app will rely on biometrics or device verification until you '
          'set a new PIN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.dangerSolid,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    svHaptic(SvHaptic.medium);
    _settings.setLockPin(null);
    svSnack(context, 'PIN removed');
  }

  Widget _form() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        TextField(
          controller: _pinController,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'New PIN',
            hintText: '4–6 digits',
            counterText: '',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _confirmController,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Confirm new PIN',
            hintText: 'Type it once more',
            counterText: '',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(onPressed: _save, child: const Text('Save PIN')),
            TextButton(onPressed: _cancelEditing, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }
}

/// Settings-card shell matching `_Card` on the Settings screen (the original
/// is file-private, so the section carries its own copy of the same recipe).
class _PinCard extends StatelessWidget {
  const _PinCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}
