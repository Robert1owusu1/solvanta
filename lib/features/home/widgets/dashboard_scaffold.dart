import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/user.dart';
import '../../../core/sync/sync.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_kit.dart';
import '../../notifications/notifications_inbox_screen.dart';
import '../../notifications/notifications_repository.dart';
import '../../search/global_search_screen.dart';
import '../../settings/settings_screen.dart';
import '../../students/students_repository.dart';
import 'command_palette.dart';
import 'home_charts.dart';
import 'home_overview.dart';
import 'home_panels.dart';

/// The group a module is listed under in the navigation menu.
enum NavSection {
  people('People'),
  daily('Attendance & Safety'),
  teaching('Teaching & Learning'),
  marking('Marking & Insights'),
  records('Reports & Records'),
  comms('Communication'),
  finance('Finance'),
  ;

  const NavSection(this.label);

  final String label;
}

class Module {
  const Module(this.icon, this.label, this.section,
      {this.subtitle = '', this.builder});

  final IconData icon;
  final String label;
  final String subtitle;
  final NavSection section;

  /// When set, the module opens [builder]; otherwise a "coming soon" notice
  /// is shown.
  final WidgetBuilder? builder;
}

/// At or above this width the menu is a sidebar that stays open and modules
/// load beside it; below it the menu is a drawer behind a hamburger and a
/// module opens as its own screen with a back button.
const sidebarBreakpoint = 1000.0;

/// The address a module has on the web: its name in lower case, words
/// joined by dashes ("Take Attendance" → `take-attendance`).
String moduleSlug(String label) =>
    label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

/// A module asked for by the address the app was opened at (a refresh or a
/// bookmark), as a slug; consumed by the first dashboard that shows.
String? pendingModuleSlug;

const _homeDest = '#home';
const _inboxDest = '#inbox';
const _accountDest = '#account';

/// App shell for every role. Large screens: a sidebar with every module,
/// grouped, and the chosen one loaded in place. Phones and small tablets:
/// a hamburger drawer with the same menu, plus Home · Menu · Inbox · Account
/// along the bottom.
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

class _DashboardScaffoldState extends State<DashboardScaffold> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The module beside the sidebar runs its own navigator; Back closes its
  /// inner pages before leaving it.
  final _moduleNav = GlobalKey<NavigatorState>();

  /// Destinations visited beside the sidebar, for Back.
  final _history = <String>[];
  final _searchFocus = FocusNode();
  var _unread = 0;
  var _overviewStamp = 0;

  /// Phone layout: 0 Home, 1 Inbox, 2 Account.
  var _tab = 0;

  /// Sidebar layout: what the content area shows — a module label or one of
  /// the `#` destinations.
  var _dest = _homeDest;
  var _query = '';
  var _collapsed = false;
  var _recent = <String>[];
  var _pinned = <String>[];

  String get _prefsKey => 'solvanta.nav.${widget.user.id}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshBadge();
    _loadPrefs();
    final slug = pendingModuleSlug;
    if (slug != null) {
      pendingModuleSlug = null;
      final m = widget.modules.where((m) => moduleSlug(m.label) == slug).firstOrNull;
      if (m != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _open(m, wide: MediaQuery.sizeOf(context).width >= sidebarBreakpoint);
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocus.dispose();
    super.dispose();
  }

  /// Browser or system Back beside the sidebar: close the module's inner
  /// page, else return to the previous module, else let the app decide.
  /// Anything shown over the dashboard (Settings, a dialog) handles Back
  /// itself first.
  @override
  Future<bool> didPopRoute() async {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (MediaQuery.sizeOf(context).width < sidebarBreakpoint) return false;
    final nav = _moduleNav.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return true;
    }
    if (_history.isEmpty) return false;
    _show(_history.removeLast(), remember: false);
    return true;
  }

  /// Moves the content area beside the sidebar to [dest], recording where
  /// it was for Back, and puts the module's address in the browser bar.
  void _show(String dest, {bool remember = true}) {
    if (dest == _dest) return;
    setState(() {
      if (remember) _history.add(_dest);
      _dest = dest;
    });
    if (kIsWeb) {
      final path = dest.startsWith('#') ? '/' : '/${moduleSlug(dest)}';
      SystemNavigator.routeInformationUpdated(uri: Uri(path: path));
    }
  }

  /// Recently opened modules and the sidebar's collapsed state are a
  /// per-person convenience: if storage is unavailable the defaults apply.
  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final recent = p.getStringList('$_prefsKey.recent') ?? const [];
      final known = {for (final m in widget.modules) m.label};
      if (!mounted) return;
      setState(() {
        _recent = recent.where(known.contains).toList();
        _pinned = (p.getStringList('$_prefsKey.pinned') ?? const []).where(known.contains).toList();
        _collapsed = p.getBool('$_prefsKey.collapsed') ?? false;
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('$_prefsKey.recent', _recent);
      await p.setStringList('$_prefsKey.pinned', _pinned);
      await p.setBool('$_prefsKey.collapsed', _collapsed);
    } catch (_) {}
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

  /// Re-pull what the home page shows: the overview panel and the badge.
  Future<void> _refresh() async {
    await StudentsRepository().active();
    await _refreshBadge();
    if (mounted) setState(() => _overviewStamp++);
  }

  void _remember(Module m) {
    _recent = [m.label, ..._recent.where((l) => l != m.label)].take(6).toList();
    _savePrefs();
  }

  /// Opens a module: beside the sidebar on a large screen, as its own
  /// screen on a small one.
  void _open(Module m, {required bool wide}) {
    svHaptic(SvHaptic.light);
    final builder = m.builder;
    if (builder == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${m.label} is coming soon')));
      return;
    }
    setState(() => _remember(m));
    if (wide) {
      _show(m.label);
    } else {
      _scaffoldKey.currentState?.closeDrawer();
      _push(builder);
    }
  }

  void _go(String dest, {required bool wide}) {
    svHaptic(SvHaptic.light);
    if (wide) {
      _show(dest);
    } else {
      _scaffoldKey.currentState?.closeDrawer();
      setState(() => _tab = switch (dest) {
            _inboxDest => 1,
            _accountDest => 2,
            _ => 0,
          });
    }
    if (dest == _inboxDest) _refreshBadge();
    if (dest == _homeDest && mounted) setState(() => _overviewStamp++);
  }

  void _togglePin(String label) {
    svHaptic(SvHaptic.light);
    final pin = !_pinned.contains(label);
    setState(() => _pinned = pin ? [..._pinned, label] : _pinned.where((l) => l != label).toList());
    _savePrefs();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(pin ? '$label pinned to the top of the menu' : '$label unpinned')));
  }

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    _savePrefs();
  }

  List<Module> get _recentModules => [
        for (final l in _recent)
          ...widget.modules.where((m) => m.label == l),
      ];

  void _logout() => AuthLogout.of(context)?.onLogout.call();

  Widget _menu({required bool wide}) => _NavPanel(
        user: widget.user,
        modules: widget.modules,
        selected: wide
            ? _dest
            : switch (_tab) {
                1 => _inboxDest,
                2 => _accountDest,
                _ => _homeDest,
              },
        collapsed: wide && _collapsed,
        query: _query,
        searchFocus: _searchFocus,
        unread: _unread,
        onQuery: (v) => setState(() => _query = v),
        onOpen: (m) => _open(m, wide: wide),
        onGo: (d) => _go(d, wide: wide),
        onToggleCollapsed: wide ? _toggleCollapsed : null,
        onSettings: () => _push((_) => const SettingsScreen()),
        onLogout: _logout,
        pinned: _pinned,
        onTogglePin: _togglePin,
      );

  Widget _home({required bool wide}) => _HomeTab(
        user: widget.user,
        listTitle: widget.listTitle,
        recent: _recentModules,
        suggested: widget.modules.take(4).toList(),
        modules: widget.modules,
        overviewStamp: _overviewStamp,
        unread: _unread,
        onOpen: (m) => _open(m, wide: wide),
        onMenu: wide ? null : () => _scaffoldKey.currentState?.openDrawer(),
        onInbox: () => _go(_inboxDest, wide: wide),
        onSearch: () => _palette(wide: wide),
        onSettings: () => _push((_) => const SettingsScreen()),
        onRefresh: _refresh,
      );

  Widget _account() => _AccountTab(
        user: widget.user,
        onSettings: () => _push((_) => const SettingsScreen()),
        onSearch: () => _push((_) => const GlobalSearchScreen()),
        onRefresh: _refresh,
      );

  Widget _content() {
    switch (_dest) {
      case _homeDest:
        return _home(wide: true);
      case _inboxDest:
        return _InboxTab(onChanged: _refreshBadge);
      case _accountDest:
        return _account();
    }
    final module = widget.modules.where((m) => m.label == _dest).firstOrNull;
    if (module?.builder == null) return _home(wide: true);
    return _ModuleHost(
      key: ValueKey(module!.label),
      navigatorKey: _moduleNav,
      module: module,
      onClosed: () => _show(_homeDest),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= sidebarBreakpoint;
      if (wide) {
        return CallbackShortcuts(
          // Ctrl/⌘+K opens the quick search, as in most web apps.
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => _palette(wide: true),
            const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => _palette(wide: true),
          },
          child: Scaffold(
            body: Column(
              children: [
                // Renders nothing when online with an empty outbox.
                const SyncStatusBanner(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _menu(wide: true),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _TopBar(
                              user: widget.user,
                              crumbs: _crumbs(),
                              onHome: () => _go(_homeDest, wide: true),
                              collapsed: _collapsed,
                              unread: _unread,
                              onToggle: _toggleCollapsed,
                              onSearch: () => _palette(wide: true),
                              onInbox: () => _go(_inboxDest, wide: true),
                              onAccount: () => _go(_accountDest, wide: true),
                              onSettings: () => _push((_) => const SettingsScreen()),
                              onLogout: _logout,
                            ),
                            Expanded(child: _content()),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(
          width: 300,
          backgroundColor: AppTheme.navy900,
          child: _menu(wide: false),
        ),
        body: Column(
          children: [
            const SyncStatusBanner(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _home(wide: false),
                  _InboxTab(onChanged: _refreshBadge),
                  _account(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: Semantics(
          container: true,
          label: 'Main navigation',
          child: NavigationBar(
            selectedIndex: switch (_tab) { 1 => 2, 2 => 3, _ => 0 },
            onDestinationSelected: (i) => switch (i) {
              0 => _go(_homeDest, wide: false),
              1 => _scaffoldKey.currentState?.openDrawer(),
              2 => _go(_inboxDest, wide: false),
              _ => _go(_accountDest, wide: false),
            },
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Home',
              ),
              const NavigationDestination(
                icon: Icon(Icons.menu),
                label: 'Menu',
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
    });
  }

  /// Where the content area is, as Home › section › module.
  List<String> _crumbs() => switch (_dest) {
        _homeDest => const ['Dashboard'],
        _inboxDest => const ['Home', 'Inbox'],
        _accountDest => const ['Home', 'My account'],
        _ => [
            'Home',
            ...widget.modules.where((m) => m.label == _dest).map((m) => m.section.label).take(1),
            _dest,
          ],
      };

  /// The quick search: menu items, and students and assessments for staff.
  void _palette({required bool wide}) => showCommandPalette(
        context,
        user: widget.user,
        modules: widget.modules,
        onModule: (m) => _open(m, wide: wide),
        onPush: _push,
      );
}

/// Hosts a module beside the sidebar in its own navigator, so the screens it
/// opens stay in the content area and its back buttons return within it.
/// Closing the module's first screen returns to Home.
class _ModuleHost extends StatelessWidget {
  const _ModuleHost({super.key, required this.navigatorKey, required this.module, required this.onClosed});

  final GlobalKey<NavigatorState> navigatorKey;
  final Module module;
  final VoidCallback onClosed;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Navigator(
        key: navigatorKey,
        pages: [
          MaterialPage<void>(
            key: ValueKey(module.label),
            name: module.label,
            child: Builder(builder: module.builder!),
          ),
        ],
        onDidRemovePage: (_) => onClosed(),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// The menu: a sidebar on large screens, the drawer on small ones.
// -----------------------------------------------------------------------------

class _NavPanel extends StatelessWidget {
  const _NavPanel({
    required this.user,
    required this.modules,
    required this.selected,
    required this.collapsed,
    required this.query,
    required this.searchFocus,
    required this.unread,
    required this.onQuery,
    required this.onOpen,
    required this.onGo,
    required this.onToggleCollapsed,
    required this.onSettings,
    required this.onLogout,
    required this.pinned,
    required this.onTogglePin,
  });

  final User user;
  final List<Module> modules;

  /// Labels pinned to the top of the menu, in the order pinned.
  final List<String> pinned;
  final ValueChanged<String> onTogglePin;
  final String selected;
  final bool collapsed;
  final String query;
  final FocusNode searchFocus;
  final int unread;
  final ValueChanged<String> onQuery;
  final ValueChanged<Module> onOpen;
  final ValueChanged<String> onGo;

  /// Null in the drawer, which has no collapsed form.
  final VoidCallback? onToggleCollapsed;
  final VoidCallback onSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    final shown = collapsed || q.isEmpty
        ? modules
        : modules
            .where((m) =>
                m.label.toLowerCase().contains(q) ||
                m.subtitle.toLowerCase().contains(q) ||
                m.section.label.toLowerCase().contains(q))
            .toList();
    final sections = [
      for (final s in NavSection.values)
        if (shown.any((m) => m.section == s)) s,
    ];
    final top = onToggleCollapsed == null ? MediaQuery.of(context).padding.top : 0.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: onToggleCollapsed == null ? null : (collapsed ? 76 : 272),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.navy900, AppTheme.navy700],
        ),
      ),
      child: Semantics(
        container: true,
        label: 'Main menu',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: top + 12),
            _brand(),
            if (!collapsed) _search(),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                children: [
                  _NavItem(
                    icon: Icons.dashboard_outlined,
                    label: 'Home',
                    selected: selected == _homeDest,
                    collapsed: collapsed,
                    onTap: () => onGo(_homeDest),
                  ),
                  if (pinnedModules.isNotEmpty && q.isEmpty) ...[
                    _SectionLabel('Pinned', collapsed: collapsed),
                    for (final m in pinnedModules) _item(m),
                  ],
                  for (final s in sections) ...[
                    _SectionLabel(s.label, collapsed: collapsed),
                    for (final m in shown.where((m) => m.section == s)) _item(m),
                  ],
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Nothing matches "$query"',
                          style: TextStyle(color: Colors.white.withValues(alpha: .85))),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: .12)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                children: [
                  _NavItem(
                    icon: Icons.notifications_none,
                    label: 'Inbox',
                    badge: unread,
                    selected: selected == _inboxDest,
                    collapsed: collapsed,
                    onTap: () => onGo(_inboxDest),
                  ),
                  _NavItem(
                    icon: Icons.person_outline,
                    label: user.name,
                    tooltip: user.role.label,
                    selected: selected == _accountDest,
                    collapsed: collapsed,
                    onTap: () => onGo(_accountDest),
                  ),
                  _NavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: false,
                    collapsed: collapsed,
                    onTap: onSettings,
                  ),
                  _NavItem(
                    icon: Icons.logout,
                    label: 'Sign out',
                    selected: false,
                    collapsed: collapsed,
                    onTap: onLogout,
                  ),
                ],
              ),
            ),
            SizedBox(height: onToggleCollapsed == null ? MediaQuery.of(context).padding.bottom : 0),
          ],
        ),
      ),
    );
  }

  List<Module> get pinnedModules => [
        for (final l in pinned) ...modules.where((m) => m.label == l),
      ];

  Widget _item(Module m) => _NavItem(
        icon: m.icon,
        label: m.label,
        tooltip: m.subtitle,
        selected: selected == m.label,
        collapsed: collapsed,
        pinned: pinned.contains(m.label),
        onPin: () => onTogglePin(m.label),
        onTap: () => onOpen(m),
      );

  Widget _brand() {
    final logo = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: AppTheme.gold,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: const Text('S',
          style: TextStyle(color: AppTheme.navy900, fontWeight: FontWeight.w900, fontSize: 17)),
    );
    if (collapsed) {
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: Center(child: logo));
    }
    return Padding(
      padding: const EdgeInsets.only(left: 18, right: 12, bottom: 10),
      child: Row(
        children: [
          logo,
          const SizedBox(width: 10),
          const Expanded(
            child: Text('SOLVANTA',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1.2)),
          ),
        ],
      ),
    );
  }

  Widget _search() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: TextField(
          focusNode: searchFocus,
          onChanged: onQuery,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          cursorColor: AppTheme.gold,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Filter menu',
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: .85), fontSize: 13.5),
            prefixIcon: Icon(Icons.search, size: 20, color: Colors.white.withValues(alpha: .7)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: .08),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.collapsed});

  final String text;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Divider(height: 1, color: Colors.white.withValues(alpha: .14)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          // 75% white clears 4.5:1 down to the sidebar's lighter end.
          color: Colors.white.withValues(alpha: .75),
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
    this.tooltip = '',
    this.badge = 0,
    this.pinned,
    this.onPin,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool selected;
  final bool collapsed;
  final int badge;
  final VoidCallback onTap;

  /// Whether the module is pinned; null for items that can't be pinned.
  final bool? pinned;

  /// Pins or unpins: the star on hover, or a long press on a phone.
  final VoidCallback? onPin;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final fg = w.selected ? Colors.white : Colors.white.withValues(alpha: .78);
    Widget glyph = Icon(w.icon, size: 21, color: fg);
    if (w.badge > 0) {
      glyph = Badge(label: Text(_badgeText(w.badge)), child: glyph);
    }
    final pinned = w.pinned ?? false;
    final showStar = !w.collapsed && w.onPin != null && (pinned || _hover);
    final item = Material(
      color: w.selected ? AppTheme.brandLight : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: w.onTap,
        onLongPress: w.onPin,
        child: Container(
          height: 42,
          padding: EdgeInsets.only(left: w.collapsed ? 0 : 12, right: w.collapsed ? 0 : 2),
          alignment: w.collapsed ? Alignment.center : Alignment.centerLeft,
          child: w.collapsed
              ? glyph
              : Row(
                  children: [
                    glyph,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        w.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 14,
                          fontWeight: w.selected ? FontWeight.w800 : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (showStar)
                      IconButton(
                        tooltip: pinned ? 'Unpin ${w.label}' : 'Pin ${w.label} to the top',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        onPressed: w.onPin,
                        icon: Icon(pinned ? Icons.star_rounded : Icons.star_outline_rounded,
                            color: pinned ? AppTheme.gold : Colors.white.withValues(alpha: .7)),
                      ),
                  ],
                ),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: Semantics(
          button: true,
          selected: w.selected,
          label: w.tooltip.isEmpty ? w.label : '${w.label}. ${w.tooltip}',
          child: w.collapsed || w.tooltip.isNotEmpty
              ? Tooltip(
                  message: w.collapsed ? w.label : w.tooltip,
                  waitDuration: const Duration(milliseconds: 500),
                  preferBelow: false,
                  child: item,
                )
              : item,
        ),
      ),
    );
  }
}

/// The white bar above the content beside the sidebar: menu toggle, the
/// app's name, search, notifications and the signed-in person.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.user,
    required this.crumbs,
    required this.onHome,
    required this.collapsed,
    required this.unread,
    required this.onToggle,
    required this.onSearch,
    required this.onInbox,
    required this.onAccount,
    required this.onSettings,
    required this.onLogout,
  });

  final User user;

  /// Home › section › module; the first is a link home unless it is the
  /// only one.
  final List<String> crumbs;
  final VoidCallback onHome;
  final bool collapsed;
  final int unread;
  final VoidCallback onToggle;
  final VoidCallback onSearch;
  final VoidCallback onInbox;
  final VoidCallback onAccount;
  final VoidCallback onSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.ink.withValues(alpha: .08))),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: collapsed ? 'Expand menu' : 'Collapse menu',
            onPressed: onToggle,
            icon: Icon(collapsed ? Icons.menu : Icons.menu_open, color: AppColors.ink),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: 'Solvanta ', style: TextStyle(color: AppColors.ink)),
                    TextSpan(text: 'School Management', style: TextStyle(color: AppColors.info)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.2),
                ),
                _Breadcrumbs(crumbs: crumbs, onHome: onHome),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Search (Ctrl+K)',
            onPressed: onSearch,
            icon: Icon(Icons.search, color: AppColors.ink),
          ),
          IconButton(
            tooltip: 'Notifications',
            onPressed: onInbox,
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(_badgeText(unread)),
              child: Icon(Icons.notifications_none, color: AppColors.ink),
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: 'Account menu',
            position: PopupMenuPosition.under,
            onSelected: (v) => switch (v) {
              'account' => onAccount(),
              'settings' => onSettings(),
              _ => onLogout(),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'account', child: ListTile(leading: Icon(Icons.person_outline), title: Text('My account'))),
              PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Settings'))),
              PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout), title: Text('Sign out'))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: AppTheme.brand,
                    child: Text(_initials(user.name),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink)),
                        Text(user.role.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  Icon(Icons.expand_more, size: 18, color: AppColors.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.crumbs, required this.onHome});

  final List<String> crumbs;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12.5, color: AppColors.muted);
    return Semantics(
      label: 'You are in ${crumbs.join(', ')}',
      child: Row(
        children: [
          for (var i = 0; i < crumbs.length; i++) ...[
            if (i > 0) Icon(Icons.chevron_right, size: 14, color: AppColors.muted),
            if (i == 0 && crumbs.length > 1)
              InkWell(
                onTap: onHome,
                borderRadius: BorderRadius.circular(4),
                child: Text(crumbs[i], style: style.copyWith(color: AppColors.brand, fontWeight: FontWeight.w600)),
              )
            else
              Flexible(
                child: Text(crumbs[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: i == crumbs.length - 1 ? style.copyWith(color: AppColors.body, fontWeight: FontWeight.w600) : style),
              ),
          ],
        ],
      ),
    );
  }
}

/// A plain page title for the content area beside the sidebar.
class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 14, color: AppColors.muted)),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Home
// -----------------------------------------------------------------------------

/// Home: the hero, "What needs attention", and the modules opened most
/// recently — the rest are one tap away in the menu rather than a long grid.
class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.user,
    required this.listTitle,
    required this.recent,
    required this.suggested,
    required this.modules,
    required this.overviewStamp,
    required this.unread,
    required this.onOpen,
    required this.onMenu,
    required this.onInbox,
    required this.onSearch,
    required this.onSettings,
    required this.onRefresh,
  });

  final User user;
  final String listTitle;
  final List<Module> recent;
  final List<Module> suggested;

  /// Every module the person has, to open "View all" targets by name.
  final List<Module> modules;
  final int overviewStamp;
  final int unread;
  final ValueChanged<Module> onOpen;

  /// Opens the drawer; null beside a sidebar.
  final VoidCallback? onMenu;
  final VoidCallback onInbox;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final Future<void> Function() onRefresh;

  VoidCallback? _opener(String label) {
    final m = modules.where((m) => m.label == label).firstOrNull;
    return m == null ? null : () => onOpen(m);
  }

  @override
  Widget build(BuildContext context) {
    final quick = recent.isNotEmpty ? recent : suggested;
    final wide = onMenu == null;
    final panels = HomePanels(
      key: ValueKey('panels-$overviewStamp'),
      user: user,
      onOpenNotices: _opener('Announcements'),
      onOpenCalendar: _opener('Academic Calendar'),
    );
    final shortcuts = <Widget>[
      if (quick.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(recent.isNotEmpty ? 'Jump back in' : listTitle,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.ink)),
              ),
              if (!wide)
                TextButton.icon(
                  onPressed: onMenu,
                  icon: const Icon(Icons.menu, size: 16),
                  label: const Text('All tools'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.brand,
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in quick)
                ActionChip(
                  avatar: Icon(m.icon, size: 18, color: AppColors.brand),
                  label: Text(m.label),
                  tooltip: m.subtitle,
                  onPressed: () => onOpen(m),
                ),
            ],
          ),
        ),
      ],
    ];
    final overview = Padding(
      padding: const EdgeInsets.only(top: 14),
      child: HomeOverview(key: ValueKey(overviewStamp), user: user),
    );
    final charts = HomeCharts(key: ValueKey('charts-$overviewStamp'), user: user);

    return SvRefresh(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 0, bottom: 24),
        children: [
          if (wide) ...[
            _PageHeading(
              title: 'Dashboard',
              subtitle: 'Welcome back, ${user.name.split(' ').where((w) => !w.endsWith('.')).firstOrNull ?? user.name}',
            ),
            // Beside the sidebar: the overview, shortcuts and charts on the
            // left, notices and what's coming up in a column on the right.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [overview, ...shortcuts, const SizedBox(height: 12), charts],
                  ),
                ),
                SizedBox(
                  width: 340,
                  child: Padding(padding: const EdgeInsets.fromLTRB(4, 14, 16, 0), child: panels),
                ),
              ],
            ),
          ] else ...[
            SvEntrance(
              offset: const Offset(0, -.08),
              duration: const Duration(milliseconds: 560),
              child: _ShellHeader(
                user: user,
                unread: unread,
                onMenu: onMenu,
                onInbox: onInbox,
                onSearch: onSearch,
                onSettings: onSettings,
                onLogout: () => AuthLogout.of(context)?.onLogout.call(),
              ),
            ),
            overview,
            ...shortcuts,
            // On a phone: what needs reading, then the charts a scroll away.
            Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: panels),
            charts,
          ],
        ],
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
    this.onMenu,
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

  /// Opens the navigation drawer (phones); null beside a sidebar.
  final VoidCallback? onMenu;
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
              if (onMenu != null) ...[
                IconButton(
                  tooltip: 'Menu',
                  onPressed: () {
                    svHaptic(SvHaptic.light);
                    onMenu!();
                  },
                  icon: const Icon(Icons.menu, color: Colors.white),
                ),
                const SizedBox(width: 2),
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
                          color: AppColors.brand,
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
          color: AppColors.brand,
          onTap: onSearch,
        ),
        _AccountAction(
          icon: Icons.settings_outlined,
          title: 'Settings',
          subtitle: 'Theme, notifications, security and data',
          color: AppColors.brand,
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


class AuthLogout extends InheritedWidget {
  const AuthLogout({super.key, required this.onLogout, required super.child});

  final VoidCallback onLogout;

  static AuthLogout? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AuthLogout>();

  @override
  bool updateShouldNotify(AuthLogout oldWidget) =>
      oldWidget.onLogout != onLogout;
}
