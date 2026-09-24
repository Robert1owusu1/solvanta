import 'package:flutter/material.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../security/security.dart';

/// Appearance, feedback, data, security and accessibility preferences.
///
/// Everything here writes through [AppSettings], which persists to
/// `shared_preferences` and notifies listeners — `SolvantaApp` rebuilds the
/// theme and the text scale in response, so changes apply live.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = AppSettings.instance;

  @override
  void initState() {
    super.initState();
    // Make sure persisted values are in before the first frame renders them.
    _settings.load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        final s = _settings;
        return Scaffold(
          appBar: SvScreenHeader(title: 'Settings', subtitle: 'Appearance, alerts & privacy'),
          body: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              // -------------------------------------------------------------
              const SvSectionTitle('Appearance'),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Label('Theme'),
                    const SizedBox(height: 10),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text('Light'),
                          icon: Icon(Icons.light_mode_outlined),
                        ),
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('System'),
                          icon: Icon(Icons.settings_brightness_outlined),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text('Dark'),
                          icon: Icon(Icons.dark_mode_outlined),
                        ),
                      ],
                      selected: {s.themeMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (v) {
                        svHaptic(SvHaptic.selection);
                        s.setThemeMode(v.first);
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'System follows your device setting. Brand colours and '
                      'marking states stay identical in every theme.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),

              // -------------------------------------------------------------
              const SvSectionTitle('Feedback'),
              _SwitchRow(
                icon: Icons.vibration,
                color: AppColors.info,
                title: 'Haptic feedback',
                subtitle: 'Tick on marking, check-in and navigation',
                value: s.haptics,
                onChanged: (v) {
                  if (v) svHaptic(SvHaptic.medium);
                  s.setHaptics(v);
                },
              ),

              // -------------------------------------------------------------
              const SvSectionTitle('Data & storage'),
              _SwitchRow(
                icon: Icons.data_saver_on_outlined,
                color: AppTheme.gold,
                title: 'Data saver (offline lite)',
                subtitle: 'Prefer cached data, skip shimmer and heavy fetches',
                value: s.dataSaver,
                onChanged: s.setDataSaver,
              ),
              _SwitchRow(
                icon: Icons.notifications_outlined,
                color: AppColors.info,
                title: 'Notifications',
                subtitle: 'Attendance, results, messages and reminders',
                value: s.notificationsEnabled,
                onChanged: s.setNotificationsEnabled,
              ),

              // -------------------------------------------------------------
              const SvSectionTitle('Security'),
              _SwitchRow(
                icon: Icons.lock_outline,
                color: AppColors.brand,
                title: 'App lock',
                subtitle: 'Require biometrics or PIN when the app opens',
                value: s.lockEnabled,
                onChanged: (v) {
                  svHaptic(SvHaptic.medium);
                  s.setLockEnabled(v);
                },
              ),
              if (s.lockEnabled)
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Label('Unlock method'),
                      const SizedBox(height: 10),
                      SvFilterChips(
                        options: [
                          SvFilterOption('Biometric',
                              selected: s.lockMethod == 'biometric'),
                          SvFilterOption('PIN',
                              selected: s.lockMethod == 'pin'),
                        ],
                        onSelected: (i) {
                          svHaptic(SvHaptic.selection);
                          s.setLockMethod(i == 0 ? 'biometric' : 'pin');
                        },
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),

              // PIN set / change / remove — self-hides while lock is off.
              const LockSettingsSection(),

              // -------------------------------------------------------------
              const SvSectionTitle('Accessibility'),
              _SwitchRow(
                icon: Icons.format_size,
                color: AppColors.info,
                title: 'Larger text',
                subtitle: 'Scale all text up by about 25%',
                value: s.largeText,
                onChanged: s.setLargeText,
              ),
              _SwitchRow(
                icon: Icons.animation,
                color: AppColors.info,
                title: 'Reduce motion',
                subtitle: 'Replace entrance animations with a simple fade',
                value: s.reduceMotion,
                onChanged: s.setReduceMotion,
              ),
              const _Note(
                'Status is never shown by colour alone: every state carries an '
                'icon and a text label, and the app respects your device '
                'text size.',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

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

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: AppColors.muted,
        letterSpacing: .2,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style:
                      TextStyle(fontSize: 11.5, height: 1.35, color: AppColors.muted),
                ),
              ],
            ),
          ),
          Semantics(
            toggled: value,
            label: '$title, ${value ? 'on' : 'off'}',
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.brand,
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.accessibility_new, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}
