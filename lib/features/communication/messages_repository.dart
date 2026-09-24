import '../../core/models/message.dart';
import '../../core/storage/local_store.dart';
import '../../core/sync/connectivity_monitor.dart';
import '../../core/sync/sync_queue.dart';

/// Persists parent↔teacher conversation threads in the offline-first local
/// store (SharedPreferences), with per-message delivery receipts and an
/// outbox-backed offline send.
///
/// Threading model: every message resolves to a canonical
/// [Message.conversationId] (see [conversationIdFor]), so a conversation is a
/// real thread regardless of who wrote last. Receipts only move forward:
/// `queued → sent → delivered → read` (see [MessageState]).
class MessagesRepository {
  MessagesRepository({LocalStore? store}) : _store = store ?? LocalStore();

  final LocalStore _store;

  /// Sync-outbox kind used for messages captured while the device was
  /// offline. The payload carries `method`/`path`/`body`, so an `ApiClient`
  /// replay handler can re-issue the POST verbatim; in a local-only install
  /// [_replayLocally] instead promotes the message to `sent` when the outbox
  /// replays it.
  static const String sendKind = 'message.send';

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  /// Every stored message (order preserved as persisted).
  Future<List<Message>> messages() => _store.loadMessages();

  /// Messages of one conversation, oldest first.
  Future<List<Message>> forConversation(String conversationId) async {
    final all = await _store.loadMessages();
    final out = all.where((m) => m.conversationId == conversationId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return out;
  }

  /// Count of messages addressed to [forId] that the recipient hasn't read.
  Future<int> unreadCount(String forId) async {
    final all = await _store.loadMessages();
    return all
        .where((m) =>
            m.toId == forId && m.state != MessageState.read && !m.read)
        .length;
  }

  /// Unread count for a single conversation — drives the list unread pill.
  Future<int> unreadIn(String meId, String conversationId) async {
    final all = await _store.loadMessages();
    return all
        .where((m) =>
            m.toId == meId &&
            m.conversationId == conversationId &&
            m.state != MessageState.read &&
            !m.read)
        .length;
  }

  // ---------------------------------------------------------------------
  // Receipts
  // ---------------------------------------------------------------------

  /// Marks every message [meId] received in [conversationId] as read,
  /// stamping [Message.readAt]. Idempotent — called when the recipient opens
  /// or scrolls the thread; a no-op (no write) when nothing changed.
  Future<void> markRead({
    required String meId,
    required String conversationId,
  }) async {
    final all = await _store.loadMessages();
    var changed = false;
    final updated = all.map((m) {
      if (m.toId != meId ||
          m.conversationId != conversationId ||
          m.state == MessageState.read) {
        return m;
      }
      changed = true;
      return m.copyWith(read: true, state: MessageState.read);
    }).toList();
    if (changed) await _store.saveMessages(updated);
  }

  /// Promotes messages [meId] received in [conversationId] from `sent` to
  /// `delivered` — the recipient's inbox has loaded them. Idempotent.
  Future<void> markDelivered({
    required String meId,
    required String conversationId,
  }) async {
    final all = await _store.loadMessages();
    var changed = false;
    final updated = all.map((m) {
      if (m.toId != meId ||
          m.conversationId != conversationId ||
          m.state != MessageState.sent) {
        return m;
      }
      changed = true;
      return m.copyWith(state: MessageState.delivered);
    }).toList();
    if (changed) await _store.saveMessages(updated);
  }

  /// Legacy entry point kept for existing call sites: marks the unread
  /// messages addressed to [meId] inside [thread] as read (delegates to
  /// [markRead] per conversation).
  Future<void> markThreadRead({
    required String meId,
    required List<Message> thread,
  }) async {
    final ids = <String>{};
    for (final m in thread) {
      if (m.toId == meId && m.state != MessageState.read) {
        ids.add(m.conversationId);
      }
    }
    for (final id in ids) {
      await markRead(meId: meId, conversationId: id);
    }
  }

  /// Promotes queued messages whose outbox entry has been replayed (or that
  /// the outbox no longer holds) back to `sent`. Cheap and idempotent — call
  /// it whenever a messaging screen loads so an offline send that finally
  /// synced stops showing as `queued`.
  Future<void> reconcileQueued() async {
    final all = await _store.loadMessages();
    final queued =
        all.where((m) => m.state == MessageState.queued).toList();
    if (queued.isEmpty) return;
    final pendingIds =
        (await SyncQueue.instance.pending()).map((i) => i.id).toSet();
    final stillQueued = queued
        .where((m) => pendingIds.contains(m.id))
        .map((m) => m.id)
        .toSet();
    final updated = all
        .map((m) =>
            m.state == MessageState.queued && !stillQueued.contains(m.id)
                ? m.copyWith(state: MessageState.sent)
                : m)
        .toList();
    await _store.saveMessages(updated);
  }

  // ---------------------------------------------------------------------
  // Send
  // ---------------------------------------------------------------------

  /// Appends a new message to its thread and returns it.
  ///
  /// Online it is persisted as [MessageState.sent]; offline it is persisted
  /// immediately as [MessageState.queued] *and* captured in
  /// [SyncQueue.instance] (kind [sendKind]) so it survives restarts and is
  /// replayed when connectivity returns. The local store write always
  /// happens first, so a send never disappears from the UI.
  Future<Message> send({
    required String fromId,
    required String toId,
    String? relatedStudentId,
    required String subject,
    required String body,
  }) async {
    final all = await _store.loadMessages();
    final online = await ConnectivityMonitor.instance.isOnline;
    final msg = Message(
      id: 'MSG-${DateTime.now().millisecondsSinceEpoch}',
      fromId: fromId,
      toId: toId,
      relatedStudentId: relatedStudentId,
      subject: subject,
      body: body,
      timestamp: _stamp(),
      state: online ? MessageState.sent : MessageState.queued,
    );
    await _store.saveMessages([...all, msg]);
    if (!online) await _captureOffline(msg);
    return msg;
  }

  // ---------------------------------------------------------------------
  // Outbox
  // ---------------------------------------------------------------------

  /// Captures [msg] in the durable outbox for replay. The delivery slot goes
  /// to `ApiClient` if it exists (it re-issues our `POST /messages` verbatim);
  /// we only ever claim the *observer* slot, which runs after a successful
  /// replay to promote the local copy from `queued` to `sent`. Registering
  /// never clobbers an existing handler, and never blocks `ApiClient` from
  /// installing one later.
  Future<void> _captureOffline(Message msg) async {
    SyncQueue.instance.registerObserver(_replayLocally);
    await SyncQueue.instance.enqueue(
      sendKind,
      {
        'method': 'POST',
        'path': '/messages',
        'body': msg.toJson(),
        'messageId': msg.id,
      },
      id: msg.id, // idempotent: one outbox entry per message
    );
  }

  /// Local bookkeeping: the message already lives in the store, so once the
  /// outbox entry is replayed we promote it. Foreign kinds are left alone
  /// (and, with no delivery handler installed, stay queued).
  Future<bool> _replayLocally(SyncItem item) async {
    if (item.kind != sendKind) return false;
    final id = (item.payload['messageId'] as String?) ?? item.id;
    final all = await _store.loadMessages();
    var changed = false;
    final updated = all.map((m) {
      if (m.id != id || m.state != MessageState.queued) return m;
      changed = true;
      return m.copyWith(state: MessageState.sent);
    }).toList();
    if (changed) await _store.saveMessages(updated);
    return true;
  }

  String _stamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p(n.month)}-${p(n.day)}T${p(n.hour)}:${p(n.minute)}';
  }
}
