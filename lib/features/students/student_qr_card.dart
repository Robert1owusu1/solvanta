import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Premium student QR ID card (doc §40). Navy gradient header with initials
// and a gold hairline, verification glyph, QR on pure white for reliable
// scanning. `qr_flutter` 4.1: no `foregroundColor` (deprecated) — eyes and
// modules are styled through QrEyeStyle / QrDataModuleStyle; the view is
// never constructed with `const`.
// ---------------------------------------------------------------------------

/// Compact JSON embedded in the QR code. Short keys keep the payload (and
/// therefore the code) small and easy to scan while still carrying the
/// student id, name, school and admission number.
String studentQrPayload(Student student, String schoolName) =>
    jsonEncode(<String, Object?>{
      'v': 1,
      'id': student.id,
      'name': student.fullName,
      'adm': student.admissionNo,
      'sch': schoolName,
      'cls': student.classId,
    });

/// The premium student ID card: navy gradient header (initials avatar,
/// name, class/admission, gold verification glyph), gold hairline, and the
/// student's QR code on pure white. Brand ratio preserved — navy frame,
/// gold accent, neutral body; dark-mode safe via [AppColors] getters.
class StudentQrCard extends StatelessWidget {
  const StudentQrCard({
    super.key,
    required this.student,
    required this.schoolName,
    this.qrSize = 196,
  });

  /// Student the card identifies.
  final Student student;

  /// School name printed under the QR (letterhead identity).
  final String schoolName;

  /// Edge length of the QR code in logical pixels.
  final double qrSize;

  @override
  Widget build(BuildContext context) {
    final payload = studentQrPayload(student, schoolName);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.ink.withValues(alpha: .10),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Navy gradient header --------------------------------
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.brand, AppTheme.brandLight],
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.gold, width: 1.5),
                    color: Colors.white.withValues(alpha: .12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    student.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        student.fullName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${student.classId} · ${student.admissionNo}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .78),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.verified,
                  color: AppTheme.gold,
                  size: 26,
                  semanticLabel: 'Verified student identity',
                ),
              ],
            ),
          ),

          // --- Gold hairline (the ~10% accent, one gesture) ---------
          Container(height: 2, color: AppTheme.gold),

          // --- QR on pure white + identity facts --------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: QrImageView(
                    data: payload,
                    size: qrSize,
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white,
                    semanticsLabel:
                        'QR code for ${student.fullName}, admission '
                        '${student.admissionNo}',
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: AppTheme.brand,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _fact('Admission', student.admissionNo),
                    _fact('Class', student.classId),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.school, size: 15, color: AppColors.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        schoolName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.body,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(height: 1, color: AppColors.border),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.qr_code_scanner,
                      size: 14,
                      color: AppColors.goldFg,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'SOLVANTA · Scan at the gate to verify',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fact(String label, String value) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
        ),
      );
}
