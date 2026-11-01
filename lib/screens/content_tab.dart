import 'package:flutter/material.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/content_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/liquid_nav_bar.dart';
import '../widgets/true_colors.dart';
import 'booking_sheet.dart';
import 'content_viewer.dart';
import 'payments_screen.dart';

enum _Tab { home, reels, videos, blogs, images, repos, podcasts, saved }

extension on _Tab {
  String get label => switch (this) {
    _Tab.home => 'Home',
    _Tab.saved => 'Saved Items',
    _ => type!.plural,
  };

  /// Shorter labels for the section bar and the Home shortcuts.
  String get navLabel => this == _Tab.saved ? 'Saved' : label;

  IconData get icon => switch (this) {
    _Tab.home => Icons.home_outlined,
    _Tab.saved => Icons.bookmark_border_rounded,
    _ => typeIcon(type!),
  };

  ContentType? get type => switch (this) {
    _Tab.reels => ContentType.reel,
    _Tab.videos => ContentType.video,
    _Tab.blogs => ContentType.blog,
    _Tab.images => ContentType.image,
    _Tab.repos => ContentType.repo,
    _Tab.podcasts => ContentType.podcast,
    _ => null,
  };
}

class _Filters {
  const _Filters({this.category, this.subcategory, this.types = const {}, this.premium});

  final String? category;
  final String? subcategory;
  final Set<ContentType> types;

  /// null = any, true = Premium only, false = Free only.
  final bool? premium;

  int get count => [category != null, subcategory != null, types.isNotEmpty, premium != null].where((b) => b).length;

  bool matches(ContentItem i) =>
      (category == null || i.category == category) &&
      (subcategory == null || i.subcategory == subcategory) &&
      (types.isEmpty || types.contains(i.type)) &&
      (premium == null || i.premium == premium);
}

/// Seeker Content: reels, videos, blogs, images, repos and podcasts, with
/// filters, saved folders and the free/premium access rules.
class ContentTab extends StatefulWidget {
  const ContentTab({super.key, required this.user, required this.onViewBookings});

  final AppUser user;
  final VoidCallback onViewBookings;

  /// Set to open a section (e.g. Videos) from elsewhere, such as the
  /// dashboard's content cards.
  static final section = ValueNotifier<ContentType?>(null);

  @override
  State<ContentTab> createState() => _ContentTabState();
}

class _ContentTabState extends State<ContentTab> {
  /// Sections in the bottom bar; the rest open from shortcuts on Home.
  static const _navTabs = [_Tab.home, _Tab.reels, _Tab.videos, _Tab.blogs, _Tab.podcasts];
  static const _homeShortcuts = [_Tab.images, _Tab.repos, _Tab.saved];

  final _service = ContentService.instance;
  final _search = TextEditingController();
  final _hero = PageController(viewportFraction: 1);
  _Tab _tab = _Tab.home;
  _Filters _filters = const _Filters();
  int _heroIndex = 0;
  String? _folder;

  AppUser get _user => widget.user;

  void _openPlans() => PaymentsScreen.open(context, _user, tab: PaymentsTab.subscriptions);

  @override
  void initState() {
    super.initState();
    _service.load(_user);
    ContentTab.section.addListener(_openSection);
    _tab = _takeSection() ?? _tab;
  }

  /// The section asked for, if any (and clears the request).
  _Tab? _takeSection() {
    final type = ContentTab.section.value;
    if (type == null) return null;
    ContentTab.section.value = null;
    return _Tab.values.where((t) => t.type == type).firstOrNull;
  }

  void _openSection() {
    final tab = _takeSection();
    if (tab != null && mounted) setState(() => _tab = tab);
  }

  @override
  void dispose() {
    ContentTab.section.removeListener(_openSection);
    _search.dispose();
    _hero.dispose();
    super.dispose();
  }

  void _open(List<ContentItem> items, ContentItem item) {
    Navigator.of(context).push(
      glassRoute(
        ContentViewer(
          user: _user,
          items: items,
          initialIndex: items.indexOf(item),
          onOpenPlans: _openPlans,
          onViewBookings: widget.onViewBookings,
        ),
      ),
    );
  }

  /// Reels open as a swipeable feed; everything else opens on its own.
  void _openItem(ContentItem item) =>
      item.type == ContentType.reel ? _open(_service.ofType(ContentType.reel), item) : _open([item], item);

  bool _matches(ContentItem i) {
    final q = _search.text.trim().toLowerCase();
    if (!_filters.matches(i)) return false;
    if (q.isEmpty) return true;
    return [
      i.title,
      i.description,
      i.category,
      i.subcategory,
      i.solverName,
      ...i.tags,
    ].any((f) => f.toLowerCase().contains(q));
  }

  Future<void> _openFilters() async {
    final picked = await showModalBottomSheet<_Filters>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => _FilterSheet(initial: _filters, showTypes: _tab == _Tab.home || _tab == _Tab.saved),
    );
    if (picked != null) setState(() => _filters = picked);
  }

  @override
  Widget build(BuildContext context) {
    // Content has its own section bar in the same liquid-glass style as the
    // main navigation, which is hidden while Content is open.
    return Stack(
      children: [
        Positioned.fill(child: _buildBody()),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 14),
            child: LiquidNavBar(
              items: [for (final tab in _navTabs) LiquidNavItem(tab.navLabel, tab.icon)],
              // Home's shortcut sections keep Home highlighted.
              currentIndex: _navTabs.contains(_tab) ? _navTabs.indexOf(_tab) : 0,
              onSelected: (i) => setState(() => _tab = _navTabs[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) => ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _tab == _Tab.home ? 'Content' : _tab.label,
                              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
                            ),
                            Text('Read. Watch. Learn. Build. Grow.', style: AppText.caption),
                          ],
                        ),
                      ),
                      // Today's free viewing time, kept small to leave room below.
                      if (_service.metered(_user)) ...[
                        Tooltip(
                          message: _service.kycLimited(_user)
                              ? 'Free preview left (5:00 until you complete KYC). Premium needs a subscription.'
                              : 'Free content left today (10:00 a day). Premium needs a subscription.',
                          child: GlassWell(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.timer_outlined, size: 15, color: Colors.white),
                                const SizedBox(width: 5),
                                Text(
                                  '${clock(_service.freeSecondsLeft(_user))} free',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // Subscriptions are a seeker purchase.
                      SmallPillButton(label: 'Subscriptions', onPressed: _openPlans),
                    ],
                  ),
                  gap14,
                  Row(
                    children: [
                      Expanded(
                        child: GlassTextField(
                          controller: _search,
                          hint:
                              'Search ${_tab == _Tab.home || _tab == _Tab.saved ? 'content' : _tab.label.toLowerCase()}',
                          icon: Icons.search_rounded,
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GlassIconButton(icon: Icons.tune_rounded, tooltip: 'Filters', onPressed: _openFilters),
                          if (_filters.count > 0)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                child: Text(
                                  '${_filters.count}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  gap14,
                  if (_tab == _Tab.home) ...[
                    Row(
                      children: [
                        for (final tab in _homeShortcuts) ...[
                          if (tab != _homeShortcuts.first) const SizedBox(width: 10),
                          Expanded(
                            child: GlassPillButton(
                              label: tab.navLabel,
                              icon: tab.icon,
                              onPressed: () => setState(() => _tab = tab),
                            ),
                          ),
                        ],
                      ],
                    ),
                    gap14,
                  ],
                  StepSwitcher(
                    child: KeyedSubtree(key: ValueKey(_tab), child: _buildTab()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab() {
    if (_tab == _Tab.saved) return _buildSaved();
    final searching = _search.text.trim().isNotEmpty || _filters.count > 0;
    if (_tab == _Tab.home && !searching) return _buildHome();
    final type = _tab.type;
    final list = _service.items.where((i) => (type == null || i.type == type) && _matches(i)).toList();
    if (list.isEmpty) return const _Empty('No content matches your search and filters.');
    if (type == ContentType.reel) return _reelGrid(list);
    return Column(
      children: [for (final i in list) _ListCard(item: i, user: _user, onTap: () => _openItem(i))],
    );
  }

  Widget _buildHome() {
    final featured = _service.items.where((i) => i.featured).toList();
    final heroes = featured.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heroes.isNotEmpty) ...[
          SizedBox(
            height: 200,
            child: PageView(
              controller: _hero,
              onPageChanged: (i) => setState(() => _heroIndex = i),
              children: [
                for (final item in heroes)
                  _HeroCard(
                    eyebrow: 'FEATURED ${item.type.label.toUpperCase()}',
                    title: item.title,
                    text: 'By ${item.solverName} · ${item.subcategory}',
                    onTap: () => _openItem(item),
                  ),
              ],
            ),
          ),
          gap8,
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < heroes.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _heroIndex ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.white(i == _heroIndex ? 1 : 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
          gap24,
        ],
        _Rail(
          title: 'Featured for you',
          onSeeAll: () => setState(() => _tab = _Tab.videos),
          height: 210,
          children: [for (final i in featured) _TileCard(item: i, user: _user, onTap: () => _openItem(i))],
        ),
        _Rail(
          title: 'Reels',
          onSeeAll: () => setState(() => _tab = _Tab.reels),
          height: 230,
          children: [for (final i in _service.ofType(ContentType.reel)) _ReelCard(item: i, onTap: () => _openItem(i))],
        ),
        _Rail(
          title: 'Popular Blogs',
          onSeeAll: () => setState(() => _tab = _Tab.blogs),
          height: 190,
          children: [
            for (final i in _service.ofType(ContentType.blog))
              _TileCard(item: i, user: _user, onTap: () => _openItem(i)),
          ],
        ),
        _Rail(
          title: 'Videos',
          onSeeAll: () => setState(() => _tab = _Tab.videos),
          height: 210,
          children: [
            for (final i in _service.ofType(ContentType.video))
              _TileCard(item: i, user: _user, onTap: () => _openItem(i)),
          ],
        ),
        _Rail(
          title: 'Repositories',
          onSeeAll: () => setState(() => _tab = _Tab.repos),
          height: 190,
          children: [
            for (final i in _service.ofType(ContentType.repo))
              _TileCard(item: i, user: _user, onTap: () => _openItem(i)),
          ],
        ),
        _Rail(
          title: 'Podcasts',
          onSeeAll: () => setState(() => _tab = _Tab.podcasts),
          height: 210,
          children: [
            for (final i in _service.ofType(ContentType.podcast))
              _TileCard(item: i, user: _user, onTap: () => _openItem(i)),
          ],
        ),
      ],
    );
  }

  Widget _reelGrid(List<ContentItem> reels) {
    return OptionGrid(
      columns: 2,
      children: [
        for (final r in reels)
          SizedBox(
            height: 250,
            child: _ReelCard(item: r, onTap: () => _open(reels, r), expand: true),
          ),
      ],
    );
  }

  Future<void> _newFolder() async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => _NewFolderSheet(user: _user),
    );
    if (name != null && mounted) setState(() => _folder = name);
  }

  Widget _buildSaved() {
    final folders = _service.folders(_user);
    final folder = folders.containsKey(_folder) ? _folder! : ContentService.defaultFolder;
    final saved = folders[folder]!.map(_service.byId).where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in folders.entries) ...[
                GlassChip(
                  label: '${entry.key} (${entry.value.length})',
                  selected: entry.key == folder,
                  onTap: () => setState(() => _folder = entry.key),
                ),
                const SizedBox(width: 8),
              ],
              GlassChip(label: '+ New Folder', selected: false, onTap: _newFolder),
            ],
          ),
        ),
        if (folder != ContentService.defaultFolder) ...[
          gap8,
          Align(
            alignment: Alignment.centerRight,
            child: UnderlineLink(
              label: 'Delete folder',
              onTap: () {
                _service.deleteFolder(_user, folder);
                setState(() => _folder = null);
              },
            ),
          ),
        ],
        gap14,
        if (saved.isEmpty)
          const _Empty('Nothing saved here yet. Tap the bookmark on any content to save it, or create a new folder.')
        else
          for (final i in saved) _ListCard(item: i, user: _user, onTap: () => _openItem(i)),
      ],
    );
  }
}

/// Names and creates a saved-content folder. Pops the new folder's name.
class _NewFolderSheet extends StatefulWidget {
  const _NewFolderSheet({required this.user});

  final AppUser user;

  @override
  State<_NewFolderSheet> createState() => _NewFolderSheetState();
}

class _NewFolderSheetState extends State<_NewFolderSheet> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    try {
      ContentService.instance.createFolder(widget.user, name);
      Navigator.of(context).pop(name);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'New Folder',
      body: GlassTextField(
        controller: _name,
        hint: 'Folder name',
        icon: Icons.create_new_folder_outlined,
        textCapitalization: TextCapitalization.words,
        errorText: _error,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _create(),
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Create Folder', onPressed: _create),
          ),
        ],
      ),
    );
  }
}

// ---- Cards --------------------------------------------------------------------------------

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.eyebrow, required this.title, required this.text, required this.onTap});

  final String eyebrow;
  final String title;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 26,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(eyebrow, style: AppText.caption.copyWith(fontSize: 11, letterSpacing: 2)),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.15, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: AppColors.white(0.85)),
          ),
          const Spacer(),
          SmallPillButton(label: 'Explore Now', primary: true, onPressed: onTap),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.title, required this.onSeeAll, required this.height, required this.children});

  final String title;
  final VoidCallback onSeeAll;
  final double height;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
                ),
              ),
              UnderlineLink(label: 'See all', onTap: onSeeAll),
            ],
          ),
          gap8,
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: children.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) => children[i],
            ),
          ),
        ],
      ),
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({required this.item, required this.user, required this.onTap});

  final ContentItem item;
  final AppUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    return SizedBox(
      width: 176,
      child: GlassWell(
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: ContentThumb(item: item, radius: 14)),
                  const SizedBox(height: 8),
                  ContentBadge(item.subcategory),
                  const SizedBox(height: 6),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  Row(
                    children: [
                      Text(
                        item.type == ContentType.blog ? '${item.readMinutes} min read' : '${compact(item.views)} views',
                        style: AppText.caption.copyWith(fontSize: 11.5),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () => showSaveSheet(context, user, item),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            service.isSaved(user, item) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                            size: 18,
                            color: Colors.white,
                            semanticLabel: 'Save',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReelCard extends StatelessWidget {
  const _ReelCard({required this.item, required this.onTap, this.expand = false});

  final ContentItem item;
  final VoidCallback onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: expand ? null : 140,
      child: GlassWell(
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Stack(
              children: [
                // The reel's cover, with a shade so the text stays readable.
                if (item.thumbnailUrl case final url?) ...[
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: TrueColors(
                        child: Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) {
                            // Cover links expire after an hour: fetch fresh ones.
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => ContentService.instance.refreshExpiredLinks(),
                            );
                            return const SizedBox.shrink();
                          },
                        ),
                      ),
                    ),
                  ),
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.all(Radius.circular(18)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.45, 1],
                            colors: [Colors.transparent, Color(0xB3000000)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                Center(child: Icon(Icons.play_circle_outline_rounded, size: 44, color: AppColors.white(0.85))),
                if (item.premium)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: ContentBadge('Premium', icon: Icons.workspace_premium_outlined),
                  ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.visibility_outlined, size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            compact(item.views),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.item, required this.user, required this.onTap});

  final ContentItem item;
  final AppUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 108, height: 96, child: ContentThumb(item: item, radius: 14, iconSize: 28)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [ContentBadge(item.category), ContentBadge(item.type.label)],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.visibility_outlined, size: 14, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(compact(item.views), style: const TextStyle(fontSize: 12, color: Colors.white)),
                            const SizedBox(width: 12),
                            const Icon(Icons.chat_bubble_outline_rounded, size: 14, color: Colors.white),
                            const SizedBox(width: 4),
                            Text('${item.comments.length}', style: const TextStyle(fontSize: 12, color: Colors.white)),
                            const SizedBox(width: 12),
                            Text(ago(item.createdAt), style: AppText.caption.copyWith(fontSize: 11.5)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Save',
                    onPressed: () => showSaveSheet(context, user, item),
                    icon: Icon(
                      service.isSaved(user, item) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Text(text, style: AppText.body, textAlign: TextAlign.center),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial, required this.showTypes});

  final _Filters initial;
  final bool showTypes;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late String? _category = widget.initial.category;
  late String? _subcategory = widget.initial.subcategory;
  late final _types = {...widget.initial.types};
  late bool? _premium = widget.initial.premium;

  /// Only the categories and sub-categories that have published content,
  /// in the catalog's order.
  static Map<String, List<String>> _available() {
    final present = <String, Set<String>>{};
    for (final i in ContentService.instance.items) {
      if (i.category.trim().isEmpty) continue;
      final subs = present.putIfAbsent(i.category, () => {});
      if (i.subcategory.trim().isNotEmpty) subs.add(i.subcategory);
    }
    List<String> ordered(Iterable<String> known, Set<String> have) => [
      for (final k in known)
        if (have.contains(k)) k,
      for (final h in have)
        if (!known.contains(h)) h,
    ];
    return {
      for (final c in ordered(ContentService.categories.keys, present.keys.toSet()))
        c: ordered(ContentService.categories[c] ?? const [], present[c]!),
    };
  }

  @override
  Widget build(BuildContext context) {
    final available = _available();
    final subs = _category == null ? const <String>[] : available[_category] ?? const <String>[];
    Widget section(String title, List<Widget> chips) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          gap8,
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        ],
      ),
    );
    return FlowSheetFrame(
      title: 'Filter Content',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (available.isNotEmpty)
            section('Category', [
              for (final c in available.keys)
                GlassChip(
                  label: c,
                  selected: _category == c,
                  onTap: () => setState(() {
                    _category = _category == c ? null : c;
                    _subcategory = null;
                  }),
                ),
            ]),
          if (subs.isNotEmpty)
            section('Sub-Category', [
              for (final s in subs)
                GlassChip(
                  label: s,
                  selected: _subcategory == s,
                  onTap: () => setState(() => _subcategory = _subcategory == s ? null : s),
                ),
            ]),
          if (widget.showTypes)
            section('Content Type', [
              for (final t in ContentType.values)
                GlassChip(
                  label: t.label,
                  selected: _types.contains(t),
                  onTap: () => setState(() => _types.contains(t) ? _types.remove(t) : _types.add(t)),
                ),
            ]),
          section('Access Type', [
            for (final (label, value) in const [('Any', null), ('Free', false), ('Premium', true)])
              GlassChip(label: label, selected: _premium == value, onTap: () => setState(() => _premium = value)),
          ]),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Reset', onPressed: () => Navigator.of(context).pop(const _Filters())),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(
              label: 'Apply',
              onPressed: () =>
                  Navigator.of(context)
                      .pop(_Filters(category: _category, subcategory: _subcategory, types: _types, premium: _premium)),
            ),
          ),
        ],
      ),
    );
  }
}
