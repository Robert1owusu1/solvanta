import 'package:flutter/material.dart';

import '../../core/models/app_notification.dart';
import '../../core/models/message.dart';
import '../../core/models/student.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_kit.dart';
import '../communication/messages_repository.dart';
import '../notifications/notifications_repository.dart';
import '../students/students_repository.dart';

/// One match produced by [GlobalSearchScreen].
class SearchHit {
  const SearchHit({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.group,
    this.onOpen,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String group;
  final VoidCallback? onOpen;
}

/// Cross-entity search: students, messages and notifications in one field.
///
/// Everything is queried locally (offline-first), so results appear as fast
/// as the user can type. Designed to be pushed from the shell header.
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final _query = TextEditingController();

  Future<List<SearchHit>>? _hits;
  List<Student> _students = const [];
  List<AppNotification> _notifications = const [];
  List<Message> _messages = const [];

  @override
  void initState() {
    super.initState();
    _hits = _load();
    _query.addListener(_run);
  }

  @override
  void dispose() {
    _query.removeListener(_run);
    _query.dispose();
    super.dispose();
  }

  Future<List<SearchHit>> _load() async {
    final students = await StudentsRepository().active();
    final notifications = await NotificationsRepository().all();
    final messages = await MessagesRepository().messages();
    if (!mounted) return const [];
    setState(() {
      _students = students;
      _notifications = notifications;
      _messages = messages;
    });
    return _match(_query.text);
  }

  void _run() => setState(() => _hits = Future.value(_match(_query.text)));

  List<SearchHit> _match(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = <SearchHit>[];

    for (final s in _students) {
      if (s.fullName.toLowerCase().contains(q) ||
          s.admissionNo.toLowerCase().contains(q) ||
          s.classId.toLowerCase().contains(q)) {
        out.add(SearchHit(
          title: s.fullName,
          subtitle: 'Student · ${s.classId} · ${s.admissionNo}',
          icon: Icons.person_outline,
          group: 'Students',
        ));
      }
    }

    for (final m in _messages) {
      if (m.body.toLowerCase().contains(q) ||
          m.subject.toLowerCase().contains(q)) {
        out.add(SearchHit(
          title: m.subject.isEmpty ? 'Message' : m.subject,
          subtitle: 'Message · ${m.body}',
          icon: Icons.mail_outline,
          group: 'Messages',
        ));
      }
    }

    for (final n in _notifications) {
      if (n.title.toLowerCase().contains(q) ||
          n.body.toLowerCase().contains(q)) {
        out.add(SearchHit(
          title: n.title,
          subtitle: 'Notification · ${n.body}',
          icon: Icons.notifications_none,
          group: 'Notifications',
        ));
      }
    }

    return out;
  }

  List<(String, List<SearchHit>)> get _grouped {
    final all = const <SearchHit>[];
    final hits = (_hits == null) ? all : _currentHits;
    if (hits.isEmpty) return const [];
    final order = ['Students', 'Messages', 'Notifications'];
    return [
      for (final g in order)
        if (hits.where((h) => h.group == g).isNotEmpty)
          (g, hits.where((h) => h.group == g).toList()),
    ];
  }

  /// FutureBuilder hands us the value synchronously once resolved; keep the
  /// latest resolved list so the grouping getter can use it.
  List<SearchHit> _currentHits = const [];

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim();
    return Scaffold(
      appBar: SvScreenHeader(
        title: 'Search',
        subtitle: 'Students, messages and notifications',
      ),
      body: Column(
        children: [
          SvSearchField(
            controller: _query,
            hint: 'Type a name, admission number or keyword…',
            onChanged: (_) {},
          ),
          const SizedBox(height: 4),
          Expanded(
            child: FutureBuilder<List<SearchHit>>(
              future: _hits,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: SvListSkeleton(rows: 6),
                  );
                }
                if (snap.hasError) {
                  return SvErrorState(
                    title: 'Search is unavailable',
                    message: 'We couldn\'t search just now. Please try again.',
                    onRetry: () => setState(() => _hits = _load()),
                  );
                }
                final hits = snap.data ?? const <SearchHit>[];
                _currentHits = hits;
                if (q.isEmpty) {
                  return const SvEmptyState(
                    icon: Icons.search,
                    title: 'Search everything',
                    message: 'Look up a student by name or admission number, '
                        'or find a message or notification by keyword.',
                  );
                }
                if (hits.isEmpty) {
                  return SvEmptyState(
                    icon: Icons.search_off,
                    title: 'No matches for "$q"',
                    message: 'Check the spelling, or try an admission number '
                        'such as S-2023-001.',
                  );
                }
                return ListView(
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  children: [
                    for (final (group, items) in _grouped) ...[
                      SvSectionTitle('$group · ${items.length}'),
                      for (var i = 0; i < items.length; i++)
                        SvEntrance(
                          delay: Duration(milliseconds: 35 * i.clamp(0, 8)),
                          child: SvAvatarTile(
                            title: items[i].title,
                            meta: items[i].subtitle,
                            icon: items[i].icon,
                            avatarColor: AppTheme.brand,
                            onTap: items[i].onOpen,
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
