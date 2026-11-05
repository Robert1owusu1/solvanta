import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// In-app help: short answers to common questions, and where to get support.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Help & support', subtitle: 'Common questions'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          for (final f in _faqs)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 5),
              child: ExpansionTile(
                title: Text(f.$1,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                childrenPadding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 14),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.$2,
                      style: TextStyle(
                          fontSize: 14, height: 1.5, color: AppColors.body)),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.infoBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Still stuck?',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: AppColors.ink)),
                const SizedBox(height: 4),
                Text(
                  'Ask your school administrator first — they manage accounts, '
                  'classes and fees. For platform issues, contact '
                  'support@solvanta.app.',
                  style: TextStyle(fontSize: 13, color: AppColors.body),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const List<(String, String)> _faqs = [
  (
    'I work offline — will my changes be saved?',
    'Yes. SOLVANTA is offline-first: what you record is saved on your device '
        'immediately and syncs to the school server automatically when you are '
        'back online. You can keep working on a weak connection.'
  ),
  (
    'How do I record a score?',
    'Open an assessment and either capture/marking (if your school uses AI '
        'marking) or enter scores by hand against the class list. You can also '
        'bulk-upload scores from the template on the assessment screen.'
  ),
  (
    'How are fees paid?',
    'SOLVANTA does not take money in the app. Your school collects fees its own '
        'way (cash, mobile money, bank), then records them here — search the '
        'student on the Fees screen and enter the payment, or upload a CSV.'
  ),
  (
    'I forgot my password',
    'Ask your school administrator to reset it for you. For security the app '
        'does not reset passwords by itself.'
  ),
  (
    'What is two-factor authentication?',
    'An extra code from an authenticator app at sign-in, on top of your '
        'password. Turn it on in Settings → Account security. We recommend it '
        'for admins and anyone handling pupil data.'
  ),
  (
    'Can I get a copy of my data, or delete my account?',
    'Yes. In Settings → Your data you can download a copy of your personal data '
        'or request erasure of your account.'
  ),
];
