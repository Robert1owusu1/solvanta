import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';

// ---------------------------------------------------------------------------
// Gate QR scanning for the student ID card. The card embeds a compact JSON
// payload (see student_qr_card.dart → studentQrPayload), so decoding is a
// light parse of `{v,id,name,adm,sch,cls}`. The screen returns the student id
// via `Navigator.pop`; the caller resolves it against its student list and
// drives the existing confirm-and-check-in flow (a scan must never check
// anyone in by itself).
// ---------------------------------------------------------------------------

/// Maximum payload length we bother parsing (cards are a few hundred bytes).
const int _maxPayload = 2048;

/// Extracts the student id from a scanned QR payload, or null when the code
/// is not our student ID card. Pure + tolerant: `v` need not be present, but
/// the id must be a non-empty string (the caller re-validates against the
/// student list). Anything else — arbitrary QR codes, malformed JSON — is
/// treated as "not a SOLVANTA student card".
String? studentIdFromScan(String? raw) {
  if (raw == null || raw.isEmpty || raw.length > _maxPayload) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final id = decoded['id'];
    return (id is String && id.trim().isNotEmpty) ? id.trim() : null;
  } on FormatException {
    return null;
  }
}

/// Full-screen camera scanner overlay. Pops with the scanned student id, or
/// null when closed without a successful scan. The camera keeps scanning
/// until a valid SOLVANTA card payload is seen or the user backs out.
class StudentIdScannerScreen extends StatefulWidget {
  const StudentIdScannerScreen({super.key});

  @override
  State<StudentIdScannerScreen> createState() => _StudentIdScannerScreenState();
}

class _StudentIdScannerScreenState extends State<StudentIdScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;
  DateTime _lastBad = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final id = studentIdFromScan(barcode.rawValue);
      if (id != null) {
        _done = true;
        _controller.stop();
        Navigator.of(context).pop(id);
        return;
      }
    }
    // A QR that isn't a student card: nudge once, then keep scanning.
    final now = DateTime.now();
    if (now.difference(_lastBad) > const Duration(seconds: 2)) {
      _lastBad = now;
      if (mounted) {
        svSnack(
          context,
          'Not a student ID card — point at the blue ID card QR code',
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => _CameraError(error: error),
            ),
          ),
          // --- Reticle + instruction --------------------------------
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        border: Border.all(color: AppTheme.gold, width: 3),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Point at the student ID card QR code',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Check-in is confirmed by you before it is recorded',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .75),
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // --- Top bar: close + torch -------------------------------
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Close scanner',
                  onPressed: () => Navigator.of(context).pop(),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: .45),
                  ),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Torch',
                  onPressed: () async {
                    try {
                      await _controller.toggleTorch();
                    } catch (_) {
                      // No torch on this device — harmless.
                    }
                  },
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: .45),
                  ),
                  icon: const Icon(Icons.flash_on, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            denied ? Icons.no_photography : Icons.videocam_off,
            color: AppTheme.gold,
            size: 44,
          ),
          const SizedBox(height: 14),
          Text(
            denied
                ? 'Camera access is off for SOLVANTA'
                : 'The camera could not start',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            denied
                ? 'Allow camera access in Settings, or use the search field '
                    'below to check a student in by ID.'
                : 'Check the camera, then try again — or type the student ID '
                    'in the check-in screen instead.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: .75),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white38),
            ),
            icon: const Icon(Icons.keyboard, size: 18),
            label: const Text('Enter ID manually'),
          ),
        ],
      ),
    );
  }
}