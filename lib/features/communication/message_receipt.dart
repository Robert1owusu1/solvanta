import 'package:flutter/material.dart';

import '../../core/models/message.dart';
import '../../core/theme/app_theme.dart';

/// Small glyph + label pair reporting one message's delivery state.
///
/// Status is never colour alone: every state pairs an icon with its word, in
/// a neutral/muted tone (not WhatsApp-blue) so it stays on brand and works
/// on navy (mine) bubbles and neutral (theirs) surfaces alike.
class MessageReceipt extends StatelessWidget {
  const MessageReceipt({
    super.key,
    required this.state,
    this.onNavy = false,
    this.readAt,
  });

  /// The message state to render.
  final MessageState state;

  /// True when the receipt sits on a navy ("mine") bubble and needs a
  /// light-on-dark tone.
  final bool onNavy;

  /// Optional `readAt` stamp — appended to the `Read` label.
  final String? readAt;

  @override
  Widget build(BuildContext context) {
    final color = onNavy ? Colors.white70 : AppColors.muted;
    final (icon, label) = switch (state) {
      MessageState.queued => (Icons.schedule, 'Queued'),
      MessageState.sent => (Icons.check, 'Sent'),
      MessageState.delivered => (Icons.done_all, 'Delivered'),
      MessageState.read => (Icons.done_all, 'Read'),
    };
    var text = label;
    if (state == MessageState.read && readAt != null && readAt!.isNotEmpty) {
      text = '$label · ${svFormatTime(readAt!)}';
    }
    return Semantics(
      label: 'Delivery status: $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
