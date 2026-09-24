/// Delivery lifecycle of one message inside a conversation thread.
///
/// The happy path is [queued] → [sent] → [delivered] → [read]. Status is
/// always rendered as a glyph + label pair (never colour alone), using a
/// neutral/muted tone.
enum MessageState {
  /// Persisted locally and captured in the sync outbox while offline.
  queued('Queued'),

  /// Handed over locally (or replayed by the outbox) — on its way.
  sent('Sent'),

  /// Received by the recipient's inbox.
  delivered('Delivered'),

  /// The recipient opened the conversation; [Message.readAt] is stamped.
  read('Read');

  const MessageState(this.label);

  /// Human label shown next to the receipt glyph.
  final String label;

  /// Parses a persisted state name; `null` when absent/unknown so callers can
  /// fall back to the legacy `read` flag.
  static MessageState? tryParse(String? name) => switch (name) {
        'queued' => MessageState.queued,
        'sent' => MessageState.sent,
        'delivered' => MessageState.delivered,
        'read' => MessageState.read,
        _ => null,
      };
}

/// Canonical id for the conversation between [a] and [b] about [studentId].
///
/// Participants are sorted so both directions of an exchange produce the same
/// id; the optional student keeps one parent/teacher pair talking about
/// different children in separate threads.
String conversationIdFor(String a, String b, String? studentId) {
  final pair = ([a, b]..sort()).join('~');
  return studentId == null ? 'CONV-$pair' : 'CONV-$pair~$studentId';
}

String _stampNow() {
  final n = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${p(n.month)}-${p(n.day)}T${p(n.hour)}:${p(n.minute)}';
}

/// One message in a parent↔teacher conversation thread.
///
/// Backwards compatible with the original flat shape: new fields are either
/// derived (id, participants, [sentAt]) or optional with sensible defaults
/// ([state], [readAt]), so existing `const Message(...)` call sites and older
/// persisted JSON keep working unchanged.
class Message {
  final String id;
  final String fromId;
  final String toId;
  final String? relatedStudentId;
  final String subject;
  final String body;

  /// When the message was written — this is the send timestamp. ISO-ish
  /// `yyyy-MM-ddTHH:mm` string, as everywhere else in the app.
  final String timestamp;
  final bool read;

  /// Per-message delivery state — see [MessageState].
  final MessageState state;

  /// When the recipient read the message (same stamp format as
  /// [timestamp]); `null` until then.
  final String? readAt;

  const Message({
    required this.id,
    required this.fromId,
    required this.toId,
    this.relatedStudentId,
    required this.subject,
    required this.body,
    required this.timestamp,
    this.read = false,
    MessageState? state,
    this.readAt,
  }) : state = state ??
            (read ? MessageState.read : MessageState.sent);

  /// Everyone taking part in this conversation (sender + recipient).
  List<String> get participants => [fromId, toId];

  /// Id of the conversation this message belongs to — see
  /// [conversationIdFor].
  String get conversationId =>
      conversationIdFor(fromId, toId, relatedStudentId);

  /// When the message was sent, as a [DateTime] (parses [timestamp]).
  DateTime? get sentAt => DateTime.tryParse(timestamp.trim());

  /// Copy with changed delivery fields. `read`/`state` are kept consistent:
  /// flipping `read` moves the state between [MessageState.sent] and
  /// [MessageState.read] unless [state] is given explicitly, and a message
  /// reaching read gets a [readAt] stamp if it doesn't have one.
  Message copyWith({bool? read, MessageState? state, String? readAt}) {
    final newRead = read ?? this.read;
    final newState = state ??
        (read == null
            ? this.state
            : (newRead ? MessageState.read : MessageState.sent));
    var effectiveReadAt = readAt ?? this.readAt;
    if (newState == MessageState.read && effectiveReadAt == null) {
      effectiveReadAt = _stampNow();
    }
    return Message(
      id: id,
      fromId: fromId,
      toId: toId,
      relatedStudentId: relatedStudentId,
      subject: subject,
      body: body,
      timestamp: timestamp,
      read: newRead,
      state: newState,
      readAt: effectiveReadAt,
    );
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    final read = (json['read'] ?? false) as bool;
    final state = MessageState.tryParse(json['state'] as String?) ??
        (read ? MessageState.read : MessageState.sent);
    return Message(
      id: json['id'] as String,
      fromId: json['fromId'] as String,
      toId: json['toId'] as String,
      relatedStudentId: json['relatedStudentId'] as String?,
      subject: (json['subject'] ?? '') as String,
      body: json['body'] as String,
      timestamp: (json['timestamp'] ?? '') as String,
      read: read || state == MessageState.read,
      state: state,
      readAt: json['readAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fromId': fromId,
        'toId': toId,
        'relatedStudentId': relatedStudentId,
        'subject': subject,
        'body': body,
        'timestamp': timestamp,
        'read': read,
        'state': state.name,
        'readAt': readAt,
      };
}
