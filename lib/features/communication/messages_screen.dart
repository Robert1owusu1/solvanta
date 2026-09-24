import 'package:flutter/material.dart';

import '../../core/models/announcement.dart';
import '../../core/models/message.dart';
import '../../core/models/student.dart';
import '../../core/models/user.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/storage/local_store.dart';
import '../../core/ui/ui_kit.dart';
import '../auth/auth_repository.dart';
import '../students/students_repository.dart';
import 'announcements_repository.dart';
import 'announcements_screen.dart';
import 'message_receipt.dart';
import 'messages_repository.dart';

/// Friendly failure feedback that never surfaces as an unhandled exception:
/// a SnackBar on the brand danger surface (`AppColors.dangerSolid`) with
/// white text.
void messagesFailSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.dangerSolid,
        duration: const Duration(seconds: 3),
      ),
    );
}

/// Conversation list: one row per participant thread (teacher ↔ parent about
/// a student), grouped by [Thread.conversationId], with an unread pill that
/// pairs a glyph with its count.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  late Future<MessagesData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<MessagesData> _load() async {
    final repo = MessagesRepository();
    // Promote offline sends whose outbox entry has already replayed.
    await repo.reconcileQueued();
    final me = await AuthRepository().currentUser();
    if (me == null) {
      throw StateError('You need to be signed in to view messages.');
    }
    final allUsers = await LocalStore().loadUsers();
    final students = await StudentsRepository().all();
    var messages = await repo.messages();

    // This inbox has just "received" everything addressed to me — promote
    // `sent` → `delivered` so senders see the delivered receipt.
    final conversations = <String>{};
    for (final m in messages) {
      if (m.toId == me.id && m.state == MessageState.sent) {
        conversations.add(m.conversationId);
      }
    }
    for (final id in conversations) {
      await repo.markDelivered(meId: me.id, conversationId: id);
    }
    if (conversations.isNotEmpty) messages = await repo.messages();

    final announcements =
        await AnnouncementsRepository().visibleFor(me, students);
    final threads = _threads(me, allUsers, students, messages);
    return MessagesData(
        me: me,
        users: allUsers,
        students: students,
        messages: messages,
        announcements: announcements,
        threads: threads);
  }

  List<Thread> _threads(User me, List<User> allUsers, List<Student> students,
      List<Message> messages) {
    if (me.role.isTeacher) {
      final myStudents =
          students.where((s) => s.classId == me.classId).toList();
      final out = <Thread>[];
      for (final s in myStudents) {
        final parent = s.parentUserId == null
            ? null
            : allUsers
                .where((u) => u.id == s.parentUserId)
                .toList()
                .firstOrNull;
        if (parent == null) continue;
        out.add(_thread(me: me, other: parent, student: s, messages: messages));
      }
      return out;
    }
    if (me.role.isParent) {
      final mine = students.where((s) => me.studentIds.contains(s.id));
      final out = <Thread>[];
      for (final s in mine) {
        final teacher = allUsers
            .where((u) => u.role.isTeacher && u.classId == s.classId)
            .toList()
            .firstOrNull;
        if (teacher == null) continue;
        out.add(_thread(me: me, other: teacher, student: s, messages: messages));
      }
      return out;
    }
    return const [];
  }

  /// Builds one participant thread: only messages of the canonical
  /// conversation id, newest first.
  Thread _thread({
    required User me,
    required User other,
    required Student student,
    required List<Message> messages,
  }) {
    final id = conversationIdFor(me.id, other.id, student.id);
    final msgs = messages.where((m) => m.conversationId == id).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Thread(
      other: other,
      parent: me.role.isParent ? me : other,
      student: student,
      messages: msgs,
      conversationId: id,
    );
  }

  /// Staggered entrance, honouring Reduce motion / Data saver (which collapse
  /// decorative motion everywhere).
  Widget _entrance(int i, Widget child) {
    if (AppSettings.instance.motionOff) return child;
    return SvEntrance(
      delay: Duration(milliseconds: 40 * i.clamp(0, 10)),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SvScreenHeader(title: 'Messages'),
      body: FutureBuilder<MessagesData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load messages",
              message: 'We couldn\'t load your conversations. '
                  'Please try again.',
              onRetry: () => setState(() => _data = _load()),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const SvListSkeleton(rows: 5);
          }
          final d = snap.data;
          if (d == null) {
            return const SvErrorState();
          }
          if (d.threads.isEmpty && d.announcements.isEmpty) {
            return const SvEmptyState(
              icon: Icons.forum_outlined,
              title: 'No conversations yet',
              message: 'When a teacher or parent contacts you about a '
                  'student, the conversation will appear here.',
            );
          }
          if (d.threads.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [_announcementsBanner(context, d)],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: d.threads.length + (d.announcements.isEmpty ? 0 : 1),
            itemBuilder: (context, i) {
              if (d.announcements.isNotEmpty && i == 0) {
                return _announcementsBanner(context, d);
              }
              final t = d.threads[i - (d.announcements.isEmpty ? 0 : 1)];
              final last = t.messages.isNotEmpty ? t.messages.first : null;
              final unread = t.messages
                  .where((m) =>
                      m.toId == d.me.id && m.state != MessageState.read)
                  .length;
              return _entrance(
                i,
                SvPressScale(
                  child: SvAvatarTile(
                    title: t.student.fullName,
                    meta:
                        '${t.other.name} · ${last?.body ?? 'No messages yet'}',
                    initials: t.student.initials,
                    trailing: unread > 0 ? _unreadPill(unread) : null,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ThreadScreen(thread: t),
                        ),
                      );
                      if (!mounted) return;
                      setState(() => _data = _load());
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Unread pill: glyph + count together (never colour alone), on brand navy.
  Widget _unreadPill(int unread) => Semantics(
        container: true,
        label: '$unread unread message${unread == 1 ? '' : 's'}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.brand,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mark_email_unread_outlined,
                  size: 13, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                '$unread',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      );

  /// A compact panel inside Messages showing the latest school/class/
  /// emergency announcements (doc §40: announcements thread into Messages).
  Widget _announcementsBanner(BuildContext context, MessagesData d) {
    final recent = d.announcements.take(2).toList();
    final emergency = d.announcements.where((a) => a.isEmergency).isNotEmpty;
    final label = emergency ? 'Announcement' : 'Announcements';
    return Card(
      color: emergency
          ? AppColors.warningBg
          : AppTheme.brand.withValues(alpha: .06),
      child: ListTile(
        leading: Icon(Icons.campaign_outlined,
            color: emergency ? AppColors.warning : AppTheme.brand),
        title:
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          recent.map((a) => '${a.title} · ${a.authorName}').join('\n'),
          maxLines: recent.length,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const AnnouncementsScreen(),
            ),
          );
          if (!mounted) return;
          setState(() => _data = _load());
        },
      ),
    );
  }
}

class MessagesData {
  final User me;
  final List<User> users;
  final List<Student> students;
  final List<Message> messages;
  final List<Announcement> announcements;
  final List<Thread> threads;

  const MessagesData({
    required this.me,
    required this.users,
    required this.students,
    required this.messages,
    required this.announcements,
    required this.threads,
  });
}

/// One participant conversation: me ↔ [other] about [student], keyed by
/// [conversationId] (the message thread id).
class Thread {
  final User other;
  final User parent;
  final Student student;
  final List<Message> messages;
  final String conversationId;

  const Thread({
    required this.other,
    required this.parent,
    required this.student,
    required this.messages,
    required this.conversationId,
  });
}

/// Thread detail: navy "mine" bubbles / neutral "theirs" bubbles with
/// per-message receipts, a composer, and read receipts stamped when the
/// recipient opens or scrolls the conversation.
class ThreadScreen extends StatefulWidget {
  final Thread thread;

  const ThreadScreen({super.key, required this.thread});

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _input = TextEditingController();
  final _channel = MessagesRepository();
  static const _templates = [
    'Great progress this term!',
    'Please practise fractions at home.',
    'Attendance concern — please check in.',
    'Please complete pending work on the assessment.',
  ];
  late Future<MessageData> _data;

  /// Latest resolved data, so the scroll listener can check for unread
  /// messages without waiting on the future.
  MessageData? _latest;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Loads the thread, then — because the recipient has *opened* the
  /// conversation — stamps any unread messages addressed to me as read and
  /// returns the refreshed list.
  Future<MessageData> _load() async {
    await _channel.reconcileQueued();
    final me = await AuthRepository().currentUser();
    if (me == null) {
      throw StateError('You need to be signed in to send messages.');
    }
    var msgs = await _channel.forConversation(widget.thread.conversationId);
    final hasUnread =
        msgs.any((m) => m.toId == me.id && m.state != MessageState.read);
    if (hasUnread) {
      await _channel.markRead(
        meId: me.id,
        conversationId: widget.thread.conversationId,
      );
      msgs = await _channel.forConversation(widget.thread.conversationId);
    }
    return MessageData(meId: me.id, messages: msgs);
  }

  /// Scrolling the thread counts as reading it too: re-run [_load] only when
  /// something new is actually waiting (so we don't hammer the store).
  void _onScrollEnd() {
    final d = _latest;
    if (d == null || !mounted) return;
    final hasUnread =
        d.messages.any((m) => m.toId == d.meId && m.state != MessageState.read);
    if (hasUnread) setState(() => _data = _load());
  }

  Future<void> _send(String body) async {
    final text = body.trim();
    if (text.isEmpty) return;
    final me = await AuthRepository().currentUser();
    if (me == null) {
      if (mounted) {
        messagesFailSnack(context, 'Sign in to send messages.');
      }
      return;
    }
    svHaptic(SvHaptic.light);
    try {
      await _channel.send(
        fromId: me.id,
        toId: widget.thread.other.id,
        relatedStudentId: widget.thread.student.id,
        subject: _subject(text),
        body: text,
      );
      _input.clear();
      if (mounted) setState(() => _data = _load());
    } catch (_) {
      if (mounted) {
        messagesFailSnack(
            context, "Couldn't send the message. Please try again.");
      }
    }
  }

  String _subject(String body) =>
      body.length > 24 ? '${body.substring(0, 24)}…' : body;

  @override
  Widget build(BuildContext context) {
    final isTeacherInit = widget.thread.other.role.isTeacher;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.thread.student.fullName} — '
            '${widget.thread.other.name}'),
      ),
      body: FutureBuilder<MessageData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return SvErrorState(
              title: "Couldn't load this conversation",
              message: 'We couldn\'t load the messages. Please try again.',
              onRetry: () => setState(() => _data = _load()),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const _ThreadSkeleton();
          }
          final d = snap.data;
          if (d == null) return const SvErrorState();
          _latest = d;
          final msgs = d.messages;
          return Column(
            children: [
              Expanded(
                child: msgs.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No messages yet. Send the first message below.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.muted),
                          ),
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n is ScrollEndNotification) _onScrollEnd();
                          return false;
                        },
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: msgs.length + 1,
                          itemBuilder: (context, i) {
                            if (i >= msgs.length) {
                              return const SizedBox(height: 12);
                            }
                            return _bubble(msgs[i], d.meId, context);
                          },
                        ),
                      ),
              ),
              if (!isTeacherInit)
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final t in _templates)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            label: Text(t),
                            onPressed: () => _send(t),
                          ),
                        ),
                    ],
                  ),
                ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: _send,
                          decoration: const InputDecoration(
                              hintText: 'Write a message…',
                              border: OutlineInputBorder(),
                              isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 48dp target; the tooltip also serves as the
                      // semantics label for this icon-only control.
                      IconButton.filled(
                        tooltip: 'Send message',
                        onPressed: () => _send(_input.text),
                        constraints: const BoxConstraints(
                            minWidth: 48, minHeight: 48),
                        icon: const Icon(Icons.send, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// One message: mine = navy #1B3B6F with white text, theirs = neutral
  /// surface with ink text. My messages carry the glyph + label receipt.
  Widget _bubble(Message m, String meId, BuildContext context) {
    final mine = m.fromId == meId;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * .78),
        decoration: BoxDecoration(
          color: mine ? AppTheme.brand : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: mine ? null : Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.body,
                style: TextStyle(
                    color: mine ? Colors.white : AppColors.ink,
                    fontSize: 14,
                    height: 1.35)),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_bubbleTime(m.timestamp),
                    style: TextStyle(
                        fontSize: 10,
                        color: mine ? Colors.white70 : AppColors.muted)),
                if (mine) ...[
                  const SizedBox(width: 6),
                  MessageReceipt(
                    state: m.state,
                    onNavy: true,
                    readAt: m.readAt,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bubble-shaped skeleton shown while a thread loads.
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    const widths = [210.0, 150.0, 190.0, 140.0, 170.0];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < widths.length; i++) ...[
            Align(
              alignment:
                  i.isEven ? Alignment.centerRight : Alignment.centerLeft,
              child: SvSkeleton(width: widths[i], height: 52, radius: 12),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// A short, readable timestamp for a message bubble. Same-day messages show
/// just the time; older messages include the date.
String _bubbleTime(String ts) {
  final t = ts.trim();
  if (t.isEmpty) return '';
  final datePart = t.contains('T')
      ? t.split('T').first
      : (t.contains(' ') ? t.split(' ').first : t);
  final d = DateTime.tryParse(datePart);
  if (d == null) return t;
  final now = DateTime.now();
  final isToday =
      d.year == now.year && d.month == now.month && d.day == now.day;
  final time = svFormatTime(t);
  return isToday ? time : '${svFormatDate(t)} · $time';
}

class MessageData {
  final String meId;
  final List<Message> messages;

  const MessageData({required this.meId, required this.messages});
}
