import 'package:flutter/material.dart';

import '../../../core/models/user.dart';
import '../../../core/responsive.dart';
import '../../../core/sync/sync.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../../notifications/notifications_inbox_screen.dart';
import '../../notifications/notifications_repository.dart';
import '../../search/global_search_screen.dart';
import '../../settings/settings_screen.dart';
import '../../students/students_repository.dart';
import 'home_overview.dart';

/// Readiness phase shown on a dashboard module chip. Color is decorative
/// (brand family) and always paired with a label + glyph.
enum ModulePhase {
  live('Live', AppTheme.brand),
  beta('Beta', AppTheme.brandLight),
  latest('New', AppTheme.gold),
  ;

  const ModulePhase(this.label, this.tint);

  final String label;

  /// Const brand-family tint used for the pill's translucent background.
  /// Enum values must be compile-time constants, so this cannot be a
  /// brightness-aware [AppColors] getter — use [fg] for the text instead.
  final Color tint;

  /// Foreground for the pill text: the same hue lifted for dark mode so the
  /// label keeps AA contrast against [tint]'s dark counterpart.
  Color get fg => switch (this) {
        live => AppColors.brand,
        beta => AppColors.info,
        // Text-sized label: brand gold is 2.3:1 on this tint in light mode.
        latest => AppColors.goldFg,
      };
}

class Module {
  const Module(this.icon, this.label, this.phase,
      {this.subtitle = '', this.builder});

  final IconData icon;
  final String label;
  final String subtitle;
  final ModulePhase phase;

  /// When set, the module opens [builder] in a new screen; otherwise a
  /// "coming soon" notice is shown.
  final WidgetBuilder? builder;
}

/// App shell for every role: branded hero, persistent bottom navigation
/// (Home · Modules · Inbox · Account) and the role's module grid.
class DashboardScaffold extends StatefulWidget {
  const DashboardScaffold({
    super.key,
    required this.user,
    required this.listTitle,
    required this.modules,
  });

  final User user;
  final String listTitle;
  final List<Module> modules;

  @override
  State<DashboardScaffold> createState() => _DashboardScaffoldState();
}

class _DashboardScaffoldState extends State<DashboardScaffold> {
  var _unread = 0;
  var _overviewStamp = 0;
  var _tab = 0;

  /// Module finder state (Modules tab).
  var _query = '';
  var _phaseFilter = 0;

  static const _phases = ['All', 'Live', 'New', 'Beta'];

  @override
  void initState() {
    super.initState();
    _refreshBadge();
  }

  Future<void> _refreshBadge() async {
    final students = await StudentsRepository().active();
    final count = await NotificationsRepository()
        .unreadCount(widget.user, students);
    if (mounted) setState(() => _unread = count);
  }

  Future<void> _push(WidgetBuilder builder) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
    _refreshBadge();
    if (mounted) setState(() => _overviewStamp++);
  }

  void _goTab(int index) {
    if (_tab == index) return;
    svHaptic(SvHaptic.light);
    setState(() => _tab = index);
    if (index == 2) _refreshBadge();
  }

  /// Re-pull everything a tab shows: the overview panel, the badge and the
  /// module list, so pull-to-refresh is a real refresh rather than a no-op.
  Future<void> _refreshTab() async {
    await StudentsRepository().active();
    await _refreshBadge();
    if (mounted) setState(() => _overviewStamp++);
  }

  List<Module> get _filtered {
    final q = _query.trim().toLowerCase();
    return widget.modules.where((m) {
      final matchesQuery = q.isEmpty ||
          m.label.toLowerCase().contains(q) ||
          m.subtitle.toLowerCase().contains(q);
      final matchesPhase = _phaseFilter == 0 ||
          _phaseName(m.phase) == _phases[_phaseFilter];
      return matchesQuery && matchesPhase;
    }).toList();
  }

  String _phaseName(ModulePhase p) => switch (p) {
        ModulePhase.live => 'Live',
        ModulePhase.latest => 'New',
        ModulePhase.beta => 'Beta',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Renders nothing when online with an empty outbox; permanent
          // placement is safe by design.
          const SyncStatusBanner(),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _HomeTab(
                  user: widget.user,
                  listTitle: widget.listTitle,
                  modules: widget.modules,
                  overviewStamp: _overviewStamp,
                  unread: _unread,
                  onOpen: _push,
                  onSeeAll: () => _goTab(1),
                  onSearch: () => _push((_) => const GlobalSearchScreen()),
                  onSettings: () => _push((_) => const SettingsScreen()),
                  onRefresh: _refreshTab,
                ),
                _ModulesTab(
                  user: widget.user,
                  listTitle: widget.listTitle,
                  modules: widget.modules,
                  query: _query,
                  phaseFilter: _phaseFilter,
                  phases: _phases,
                  filtered: _filtered,
                  unread: _unread,
                  onQuery: (v) => setState(() => _query = v),
                  onPhase: (i) => setState(() => _phaseFilter = i),
                  onOpen: _push,
                  onSearch: () => _push((_) => const GlobalSearchScreen()),
                  onSettings: () => _push((_) => const SettingsScreen()),
                  onRefresh: _refreshTab,
                ),
                _InboxTab(onChanged: _refreshBadge),
                _AccountTab(
                  user: widget.user,
                  onSettings: () => _push((_) => const SettingsScreen()),
                  onSearch: () => _push((_) => const GlobalSearchScreen()),
                  onRefresh: _refreshTab,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Semantics(
        container: true,
        label: 'Main navigation',
        child: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _goTab,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: 'Modules',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _unread > 0,
              label: Text(_badgeText(_unread)),
              child: const Icon(Icons.notifications_none),
            ),
            selectedIcon: Badge(
              isLabelVisible: _unread > 0,
              label: Text(_badgeText(_unread)),
              child: const Icon(Icons.notifications),
            ),
            label: 'Inbox',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
        ),
      ),
    );
  }
}

/// Badge text capped so a large backlog can't stretch the pill over the icon.
String _badgeText(int n) => n > 99 ? '99+' : '$n';

/// Up to two initials for an avatar, skipping honorifics ("Ms.", "Mrs.") so
/// "Ms. Efua Mensah" reads EM; '?' when the name is blank.
String _initials(String name) {
  final words = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  final named = words.where((p) => !p.endsWith('.')).toList();
  final s = (named.isEmpty ? words : named)
      .take(2)
      .map((p) => p[0].toUpperCase())
      .join();
  return s.isEmpty ? '?' : s;
}

/// Branded hero shared by every top-level tab: greeting, role and the two
/// shell actions (inbox + sign out). Navy gradient with a gold hairline so
/// gold stays the ~10% accent rather than a full-bleed fill.
class _ShellHeader extends StatelessWidget {
  const _ShellHeader({
    this.user,
    this.title,
    this.subtitle,
    this.unread = 0,
    this.showInbox = true,
    this.onInbox,
    this.onSearch,
    this.onSettings,
    this.onLogout,
  });

  /// Signed-in user. When null (e.g. the Inbox tab) [title]/[subtitle] must
  /// be supplied and only the non-session actions are shown.
  final User? user;
  final String? title;
  final String? subtitle;
  final int unread;
  final bool showInbox;
  final VoidCallback? onInbox;
  final VoidCallback? onSearch;
  final VoidCallback? onSettings;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final firstName = (user?.name ?? '').split(' ').first;
    final canPop = Navigator.of(context).canPop();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 14,
        left: 20,
        right: 20,
        bottom: 24,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.navy900, AppTheme.navy700],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (canPop) ...[
                Ink(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .16),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: Colors.white),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              if (user != null) ...[
                CircleAvatar(
                  backgroundColor: Colors.white.withValues(alpha: .2),
                  child: Text(
                    _initials(user!.name),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title ?? 'Welcome, $firstName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.2),
                    ),
                    Text(
                      subtitle ?? user?.role.label ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: .8),
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (onSearch != null)
                IconButton(
                  tooltip: 'Search',
                  onPressed: () {
                    svHaptic(SvHaptic.light);
                    onSearch!();
                  },
                  icon: const Icon(Icons.search, color: Colors.white),
                ),
              if (showInbox && onInbox != null)
                IconButton(
                  tooltip: 'Notifications',
                  onPressed: () {
                    svHaptic(SvHaptic.light);
                    onInbox!();
                  },
                  icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text(_badgeText(unread)),
                    child:
                        const Icon(Icons.notifications, color: Colors.white),
                  ),
                ),
              if (onSettings != null)
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () {
                    svHaptic(SvHaptic.light);
                    onSettings!();
                  },
                  icon: const Icon(Icons.settings, color: Colors.white),
                ),
              if (onLogout != null)
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: () {
                    svHaptic(SvHaptic.light);
                    onLogout!();
                  },
                  icon: const Icon(Icons.logout, color: Colors.white),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // Gold accent hairline — the ~10% accent in one gesture.
          Container(
            height: 3,
            width: 56,
            decoration: BoxDecoration(
              color: AppTheme.gold,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Home tab: hero + "What needs attention" + the module grid.
class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.user,
    required this.listTitle,
    required this.modules,
    required this.overviewStamp,
    required this.unread,
    required this.onOpen,
    required this.onSeeAll,
    required this.onSearch,
    required this.onSettings,
    required this.onRefresh,
  });

  final User user;
  final String listTitle;
  final List<Module> modules;
  final int overviewStamp;
  final int unread;
  final Future<void> Function(WidgetBuilder) onOpen;
  final VoidCallback onSeeAll;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return SvRefresh(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 0, bottom: 24),
        children: [
          SvEntrance(
            offset: const Offset(0, -.08),
            duration: const Duration(milliseconds: 560),
            child: _ShellHeader(
              user: user,
              unread: unread,
              onInbox: () => onOpen((_) => const NotificationsInboxScreen()),
              onSearch: onSearch,
              onSettings: onSettings,
              onLogout: () => AuthLogout.of(context)?.onLogout.call(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: HomeOverview(
            key: ValueKey(overviewStamp),
            user: user,
          ),
        ),
        Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, top: 6, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(listTitle,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.ink)),
              ),
              TextButton.icon(
                onPressed: onSeeAll,
                icon: const Icon(Icons.search, size: 16),
                label: const Text('Find'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.brand,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        _ModuleGrid(modules: modules, onOpen: onOpen),
        ],
      ),
    );
  }
}

/// Modules tab: searchable / filterable finder for large role dashboards.
class _ModulesTab extends StatelessWidget {
  const _ModulesTab({
    required this.user,
    required this.listTitle,
    required this.modules,
    required this.query,
    required this.phaseFilter,
    required this.phases,
    required this.filtered,
    required this.unread,
    required this.onQuery,
    required this.onPhase,
    required this.onOpen,
    required this.onSearch,
    required this.onSettings,
    required this.onRefresh,
  });

  final User user;
  final String listTitle;
  final List<Module> modules;
  final String query;
  final int phaseFilter;
  final List<String> phases;
  final List<Module> filtered;
  final int unread;
  final ValueChanged<String> onQuery;
  final ValueChanged<int> onPhase;
  final Future<void> Function(WidgetBuilder) onOpen;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return SvRefresh(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 0, bottom: 24),
        children: [
          SvEntrance(
            offset: const Offset(0, -.08),
            duration: const Duration(milliseconds: 560),
            child: _ShellHeader(
              user: user,
              title: 'Modules',
              subtitle:
                  '${modules.length} tools · ${user.role.label.toLowerCase()}',
              unread: unread,
              onInbox: () => onOpen((_) => const NotificationsInboxScreen()),
              onSearch: onSearch,
              onSettings: onSettings,
              onLogout: () => AuthLogout.of(context)?.onLogout.call(),
            ),
          ),
        SvSearchField(
          hint: 'Search ${listTitle.toLowerCase()}…',
          onChanged: onQuery,
        ),
        const SizedBox(height: 10),
        SvFilterChips(
          options: [
            for (var i = 0; i < phases.length; i++)
              SvFilterOption(phases[i], selected: phaseFilter == i),
          ],
          onSelected: onPhase,
        ),
        const SizedBox(height: 6),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: SvEmptyState(
              icon: Icons.search_off,
              title: 'No modules match',
              message: 'Try a different keyword, or clear the filters '
                  'to see everything again.',
            ),
          )
        else
          _ModuleGrid(modules: filtered, onOpen: onOpen),
        ],
      ),
    );
  }
}

/// Inbox tab — the shared inbox body embedded without a nested app bar.
/// The body is its own scroll view, so it is bounded by an [Expanded]
/// rather than nested inside the tab's scroll view.
class _InboxTab extends StatelessWidget {
  const _InboxTab({required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SvEntrance(
          offset: const Offset(0, -.08),
          duration: const Duration(milliseconds: 560),
          child: const _ShellHeader(
            title: 'Inbox',
            subtitle: 'Updates that need your attention',
            showInbox: false,
          ),
        ),
        Expanded(
          child: NotificationsInboxBody(onChanged: onChanged),
        ),
      ],
    );
  }
}

/// Account tab: identity, role and session controls.
class _AccountTab extends StatelessWidget {
  const _AccountTab({
    required this.user,
    required this.onSettings,
    required this.onSearch,
    required this.onRefresh,
  });

  final User user;
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final initials = _initials(user.name);
    return SvRefresh(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 0, bottom: 24),
        children: [
          SvEntrance(
            offset: const Offset(0, -.08),
            duration: const Duration(milliseconds: 560),
            child: _ShellHeader(
              user: user,
              title: user.name,
              subtitle: user.role.label,
              showInbox: false,
              onSearch: onSearch,
              onSettings: onSettings,
              onLogout: () => AuthLogout.of(context)?.onLogout.call(),
            ),
          ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTheme.navy900, AppTheme.navy700],
                      ),
                      borderRadius: BorderRadius.all(Radius.circular(18)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      initials,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 3),
                        Text(user.email,
                            style: TextStyle(
                                fontSize: 13, color: AppColors.muted)),
                        const SizedBox(height: 6),
                        SvStatusBadge(
                          label: user.role.label,
                          icon: Icons.verified_user_outlined,
                          color: AppTheme.brand,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const SvSectionTitle('Preferences'),
        _AccountAction(
          icon: Icons.search,
          title: 'Search',
          subtitle: 'Find students, messages and alerts',
          color: AppTheme.brand,
          onTap: onSearch,
        ),
        _AccountAction(
          icon: Icons.settings_outlined,
          title: 'Settings',
          subtitle: 'Theme, notifications, security and data',
          color: AppTheme.brand,
          onTap: onSettings,
        ),
        const SizedBox(height: 10),
        const SvSectionTitle('Session'),
        _AccountAction(
          icon: Icons.logout,
          title: 'Sign out',
          subtitle: 'End this session on the device',
          color: AppColors.danger,
          onTap: () => AuthLogout.of(context)?.onLogout.call(),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'SOLVANTA · Intelligence that illuminates possibility.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppColors.muted),
          ),
        ),
        ],
      ),
    );
  }
}

class _AccountAction extends StatelessWidget {
  const _AccountAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: Semantics(
          button: true,
          label: '$title. $subtitle',
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              svHaptic(SvHaptic.light);
              onTap();
            },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppColors.ink.withValues(alpha: .06),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, color: color, size: 21),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 11.5, color: AppColors.muted)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 20, color: AppColors.muted),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

/// Two-column module grid shared by the Home and Modules tabs.
class _ModuleGrid extends StatelessWidget {
  const _ModuleGrid({required this.modules, required this.onOpen});

  final List<Module> modules;
  final Future<void> Function(WidgetBuilder) onOpen;

  @override
  Widget build(BuildContext context) {
    return ResponsiveGridView(
      minItemWidth: 200,
      maxColumns: 6,
      minColumns: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // Sits inside the dashboard's ListView, so it must size to its content.
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < modules.length; i++)
          SvEntrance(
            delay: Duration(milliseconds: 70 * (i.clamp(0, 10))),
            child: SvPressScale(
              child: _ModuleCard(
                icon: modules[i].icon,
                label: modules[i].label,
                subtitle: modules[i].subtitle,
                phase: modules[i].phase,
                opens: modules[i].builder != null,
                onTap: () {
                  if (modules[i].builder != null) {
                    onOpen(modules[i].builder!);
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(
                            '${modules[i].label} — coming in ${modules[i].phase.label}')),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// A compact two-column feature card for the dashboard grid: brand icon tile,
/// phase pill, bold label and a one-line description.
class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.phase,
    required this.opens,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final ModulePhase phase;
  final bool opens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: Semantics(
        button: true,
        label: opens ? 'Open $label' : '$label, coming soon',
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            svHaptic(SvHaptic.light);
            onTap();
          },
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: AppColors.ink.withValues(alpha: .06),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppTheme.navy900, AppTheme.navy700],
                      ),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(icon, color: Colors.white, size: 21),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: phase.tint.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (phase == ModulePhase.latest)
                          Icon(Icons.auto_awesome,
                              size: 11, color: AppColors.goldFg),
                        const SizedBox(width: 2),
                        Text(
                          phase.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: phase.fg,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    color: AppColors.ink),
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, color: AppColors.muted),
                    ),
                  ),
                  if (opens)
                    Icon(Icons.arrow_forward_rounded,
                        size: 15, color: AppColors.muted),
                ],
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class AuthLogout extends InheritedWidget {
  const AuthLogout({super.key, required this.onLogout, required super.child});

  final VoidCallback onLogout;

  static AuthLogout? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AuthLogout>();

  @override
  bool updateShouldNotify(AuthLogout oldWidget) =>
      oldWidget.onLogout != onLogout;
}
