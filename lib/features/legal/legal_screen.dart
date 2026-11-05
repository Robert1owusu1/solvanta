import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

/// The two legal documents shown in the app. These are plain-language starting
/// points meant to be reviewed by the school's/operator's legal counsel before
/// launch — not legal advice.
enum LegalDoc {
  terms('Terms of Service'),
  privacy('Privacy Policy');

  const LegalDoc(this.title);
  final String title;
}

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.doc});

  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    final sections = doc == LegalDoc.terms ? _terms : _privacy;
    return Scaffold(
      appBar: SvScreenHeader(title: doc.title, subtitle: 'Last updated 2026'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          for (final s in sections) ...[
            Text(s.$1,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink)),
            const SizedBox(height: 6),
            Text(s.$2,
                style: TextStyle(fontSize: 14, height: 1.5, color: AppColors.body)),
            const SizedBox(height: 18),
          ],
          Text(
            'This document is a plain-language template. Have it reviewed by '
            'qualified legal counsel and adapted to your jurisdiction before you '
            'rely on it.',
            style: TextStyle(
                fontSize: 12, fontStyle: FontStyle.italic, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

const List<(String, String)> _terms = [
  (
    'Using SOLVANTA',
    'SOLVANTA is a school-management and assessment platform. By creating an '
        'account or using the app you agree to use it only for legitimate '
        'school activities and to keep your sign-in credentials confidential. '
        'You are responsible for everything done under your account.'
  ),
  (
    'Roles and access',
    'Access is role-based. School admins, headteachers, teachers, staff, '
        'parents and students each see only the data and actions meant for their '
        'role. Do not attempt to access data outside your role.'
  ),
  (
    'Payments',
    'SOLVANTA does not collect fees or take payments inside the app. Schools '
        'collect fees their own way and record what they receive. Platform '
        'subscription plans beyond the free tier are arranged directly with '
        'sales; nothing is charged through the app.'
  ),
  (
    'Content and data you enter',
    'You keep ownership of the data you enter. You grant SOLVANTA permission to '
        'store and process it to provide the service. You must have the right to '
        'enter any personal data (including children’s) that you upload.'
  ),
  (
    'Availability and changes',
    'We aim for reliable service but do not guarantee uninterrupted '
        'availability. Features may change over time. We will give reasonable '
        'notice of material changes to these terms.'
  ),
  (
    'Termination',
    'An account may be suspended or closed for misuse or for breaching these '
        'terms. You may stop using the service and request deletion of your data '
        'at any time, subject to any legal retention requirements.'
  ),
];

const List<(String, String)> _privacy = [
  (
    'What we collect',
    'We collect the information schools and users enter to run the service: '
        'account details (name, email, phone, role), and school records such as '
        'students, classes, attendance, assessments, scores and fees. We also '
        'keep basic technical logs needed to operate and secure the service.'
  ),
  (
    'Children’s data',
    'Schools and independent teachers register data about children. That data is '
        'used only to provide the service to that school/teacher, is isolated per '
        'school, and is never sold or used for advertising. Independent teachers '
        'accept a data-protection notice before registering any pupil.'
  ),
  (
    'How we use it',
    'To provide and secure the platform, generate reports and analytics for the '
        'school, and count usage. We do not use your content to train external '
        'models. Any AI/OCR features process pages to produce a draft that a '
        'teacher reviews; providers are configured not to retain submitted images.'
  ),
  (
    'Sharing',
    'Data is visible within a school according to role. We do not share personal '
        'data with third parties except processors that help run the service '
        '(e.g. hosting), under contract, or where required by law.'
  ),
  (
    'Your rights',
    'You can access and correct your data in the app. You can request an export '
        'or deletion of your data; schools can export their whole dataset. We '
        'retain data only as long as needed to provide the service or as the law '
        'requires.'
  ),
  (
    'Security',
    'Passwords are stored hashed, access is authenticated and role-checked, '
        'traffic is restricted to allow-listed origins, and each school’s data '
        'is kept separate. No system is perfectly secure; report concerns to the '
        'school office or the platform operator.'
  ),
  (
    'Contact',
    'For privacy questions, contact your school administrator or the platform '
        'operator at privacy@solvanta.app.'
  ),
];
