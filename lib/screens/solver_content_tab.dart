import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/content_api.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/content_service.dart';
import '../services/skill_verification_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/clap.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/html_text.dart';
import '../widgets/liquid_nav_bar.dart';
import 'booking_sheet.dart';
import 'content_viewer.dart';

enum _Section {
  home('Home', Icons.home_outlined),
  premium('Premium', Icons.workspace_premium_outlined),
  free('Free', Icons.lock_open_rounded),
  drafts('Drafts', Icons.edit_note_rounded),
  podcasts('Podcasts', Icons.podcasts_rounded);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

String _typeName(ContentType t) => switch (t) {
  ContentType.repo => 'GitHub Repository',
  _ => t.label,
};

Future<T?> _sheet<T>(BuildContext context, Widget sheet) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => sheet,
);

/// Opens the solver's own content in the shared viewer, with their actions
/// (share, edit, analytics, unpublish, delete) in place of the seeker's.
void openOwnContent(BuildContext context, AppUser user, List<ContentItem> items, ContentItem item) {
  Navigator.of(context).push(
    glassRoute(
      ContentViewer(
        user: user,
        items: items,
        initialIndex: items.indexOf(item),
        onOpenPlans: () {},
        onViewBookings: () {},
        ownerActions: (i, vertical) => OwnerContentActions(user: user, item: i, vertical: vertical, inViewer: true),
      ),
    ),
  );
}

/// Solver Content: only the solver's own content. Home, Premium, Free,
/// Drafts and Podcasts, with creating, editing and publishing.
class SolverContentTab extends StatefulWidget {
  const SolverContentTab({super.key, required this.user});

  final AppUser user;

  @override
  State<SolverContentTab> createState() => _SolverContentTabState();
}

class _SolverContentTabState extends State<SolverContentTab> {
  final _service = ContentService.instance;
  _Section _section = _Section.home;
  ContentType? _type;

  AppUser get _user => widget.user;

  @override
  void initState() {
    super.initState();
    ContentService.instance.loadMine(_user).catchError((Object e) {
      if (mounted) _toast(context, e is AuthException ? e.message : 'Couldn\'t load your content.');
    });
  }

  Future<void> _create() async {
    final type = await _sheet<ContentType>(context, const _CreateChooser());
    if (type == null || !mounted) return;
    if (type == ContentType.podcast) {
      setState(() => _section = _Section.podcasts);
      return;
    }
    await _sheet<void>(context, ContentFormSheet(user: _user, type: type));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: _body()),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 14),
            child: LiquidNavBar(
              items: [for (final s in _Section.values) LiquidNavItem(s.label, s.icon)],
              currentIndex: _section.index,
              onSelected: (i) => setState(() => _section = _Section.values[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _body() {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final mine = _service.mine(_user);
        final published = mine.where((i) => !i.draft && i.type != ContentType.podcast).toList();
        final list = switch (_section) {
          _Section.home => published.where((i) => _type == null || i.type == _type).toList(),
          _Section.premium => published.where((i) => i.premium).toList(),
          _Section.free => published.where((i) => !i.premium).toList(),
          _Section.drafts => mine.where((i) => i.draft && i.type != ContentType.podcast).toList(),
          _Section.podcasts => mine.where((i) => i.type == ContentType.podcast).toList(),
        };
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, LiquidNavBar.clearance + MediaQuery.paddingOf(context).bottom),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _section == _Section.home ? 'Content Creator' : _section.label,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    Text('Only your own content appears here.', style: AppText.caption),
                    gap14,
                    StepSwitcher(
                      child: KeyedSubtree(
                        key: ValueKey(_section),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_section == _Section.home) ...[_hero(), gap14, _typeChips(), gap14],
                            if (_section == _Section.podcasts) ...[
                              const InlineNotice(
                                message:
                                    'Recorded podcasts are saved as drafts. Publish within 15 days or they will be '
                                    'automatically deleted.',
                              ),
                            ],
                            if (list.isEmpty)
                              _Empty(section: _section, onCreate: _create)
                            else
                              for (final item in list)
                                _MyContentCard(
                                  user: _user,
                                  item: item,
                                  onOpen: () => openOwnContent(
                                    context,
                                    _user,
                                    item.type == ContentType.reel
                                        ? list.where((i) => i.type == ContentType.reel).toList()
                                        : [item],
                                    item,
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _hero() {
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Create & Share\nYour Knowledge',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.2, color: Colors.white),
          ),
          gap8,
          Text('Publish blogs, videos, reels, repos, images and podcasts.', style: AppText.caption),
          gap14,
          PrimaryPillButton(label: '+  Create Content', onPressed: _create),
        ],
      ),
    );
  }

  Widget _typeChips() {
    final types = <ContentType?>[
      null,
      ContentType.blog,
      ContentType.video,
      ContentType.reel,
      ContentType.image,
      ContentType.repo,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final t in types) ...[
            GlassChip(label: t?.plural ?? 'All', selected: _type == t, onTap: () => setState(() => _type = t)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// ---- Card -------------------------------------------------------------------------------

class _MyContentCard extends StatelessWidget {
  const _MyContentCard({required this.user, required this.item, required this.onOpen});

  final AppUser user;
  final ContentItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final podcast = item.type == ContentType.podcast;
    final meta = AppText.caption.copyWith(fontSize: 11.5, color: AppColors.white(0.85));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassWell(
        radius: 18,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 100, height: 92, child: ContentThumb(item: item, radius: 14, iconSize: 28)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            ContentBadge(item.type.label),
                            if (item.premium) const ContentBadge('Premium', icon: Icons.workspace_premium_outlined),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${item.category} · ${item.subcategory}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        if (item.draft)
                          Text(
                            podcast
                                ? [
                                    if (item.autoRecorded) 'Auto-recorded' else 'Recorded',
                                    'on ${formatDay(item.createdAt)}',
                                    // Unpublished recordings are deleted by the server.
                                    if (item.draftExpiresAt case final at?)
                                      '· deleted ${formatDay(at)} unless published',
                                  ].join(' ')
                                : 'Last saved: ${formatDay(item.createdAt)}',
                            style: meta,
                          )
                        else
                          Wrap(
                            spacing: 10,
                            runSpacing: 2,
                            children: [
                              _Stat(Icons.visibility_outlined, compact(item.views)),
                              _Stat.clap('${item.appreciatedBy.length}'),
                              _Stat(Icons.chat_bubble_outline_rounded, '${item.comments.length}'),
                              Text(ago(item.createdAt), style: meta),
                            ],
                          ),
                        if (item.draft) ...[
                          gap8,
                          Row(
                            children: [
                              const ContentBadge('Draft'),
                              const SizedBox(width: 8),
                              _PublishButton(user: user, item: item),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'More',
                    onPressed: () => showOwnerMenu(context, user, item),
                    icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
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

class _Stat extends StatelessWidget {
  const _Stat(IconData this.icon, this.text);

  /// Appreciations, shown as claps.
  const _Stat.clap(this.text) : icon = null;

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?) Icon(icon, size: 13, color: Colors.white) else const ClapIcon(size: 13),
        const SizedBox(width: 3),
        Text(text, style: const TextStyle(fontSize: 11.5, color: Colors.white)),
      ],
    );
  }
}

/// "Publish" on a draft card.
class _PublishButton extends StatelessWidget {
  const _PublishButton({required this.user, required this.item});

  final AppUser user;
  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    return SmallPillButton(label: 'Publish', primary: true, onPressed: () => _publish(context, user, item));
  }
}

Future<void> _publish(BuildContext context, AppUser user, ContentItem item) async {
  try {
    await ContentService.instance.publish(user, item);
    if (context.mounted) _toast(context, '"${item.title}" is published.');
  } on AuthException catch (e) {
    if (context.mounted) _toast(context, e.message);
  }
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text, style: const TextStyle(color: Colors.white)),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        duration: InlineNotice.showFor,
      ),
    );
}

// ---- Owner actions ----------------------------------------------------------------------

/// Share, Edit, Analytics, Unpublish (or Publish) and Delete, in place of the
/// seeker's actions.
class OwnerContentActions extends StatelessWidget {
  const OwnerContentActions({
    super.key,
    required this.user,
    required this.item,
    this.vertical = false,
    this.inViewer = false,
  });

  final AppUser user;
  final ContentItem item;
  final bool vertical;

  /// Deleting from the viewer also closes it.
  final bool inViewer;

  @override
  Widget build(BuildContext context) {
    final actions = _ownerActions(context, user, item, inViewer: inViewer);
    if (vertical) {
      return Column(
        children: [
          for (final (icon, label, onTap) in actions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassIconButton(icon: icon, tooltip: label, onPressed: onTap),
            ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [for (final (_, label, onTap) in actions) SmallPillButton(label: label, onPressed: onTap)],
    );
  }
}

List<(IconData, String, VoidCallback)> _ownerActions(
  BuildContext context,
  AppUser user,
  ContentItem item, {
  bool inViewer = false,
}) {
  final service = ContentService.instance;
  return [
    (Icons.share_outlined, 'Share', () => _share(context, item)),
    // Podcasts too: their details, not the recording.
    (
      Icons.edit_outlined,
      'Edit',
      () => _sheet<void>(context, ContentFormSheet(user: user, type: item.type, item: item)),
    ),
    (Icons.insights_outlined, 'Analytics', () => _sheet<void>(context, _AnalyticsSheet(item: item))),
    if (item.draft)
      (Icons.publish_rounded, 'Publish', () => _publish(context, user, item))
    else
      (
        Icons.unpublished_outlined,
        'Unpublish',
        () async {
          try {
            await service.unpublish(item);
            if (context.mounted) _toast(context, '"${item.title}" moved to Drafts. Seekers can no longer see it.');
          } on AuthException catch (e) {
            if (context.mounted) _toast(context, e.message);
          }
        },
      ),
    (
      Icons.delete_outline_rounded,
      'Delete',
      () async {
        final confirmed = await _sheet<bool>(context, _ConfirmDelete(item: item));
        if (confirmed != true || !context.mounted) return;
        try {
          await service.delete(item);
        } on AuthException catch (e) {
          if (context.mounted) _toast(context, e.message);
          return;
        }
        if (inViewer && context.mounted) Navigator.of(context).maybePop();
      },
    ),
  ];
}

/// The ⋮ menu on a card.
Future<void> showOwnerMenu(BuildContext context, AppUser user, ContentItem item) async {
  final actions = _ownerActions(context, user, item);
  final picked = await _sheet<int>(
    context,
    FlowSheetFrame(
      title: item.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (icon, label, _)) in actions.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Builder(
                builder: (sheetContext) => GlassOption(
                  height: 54,
                  radius: 16,
                  selected: false,
                  onTap: () => Navigator.of(sheetContext).pop(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(icon, color: Colors.white),
                        const SizedBox(width: 12),
                        Text(label, style: AppText.label.copyWith(fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  if (picked != null && context.mounted) actions[picked].$3();
}

Future<void> _share(BuildContext context, ContentItem item) async {
  if (item.draft) {
    _toast(context, 'Publish it first. Drafts can\'t be shared.');
    return;
  }
  final user = AuthService.instance.currentUser;
  if (user == null) return;
  await shareContent(user, item);
}

// ---- Sheets -----------------------------------------------------------------------------

class _CreateChooser extends StatelessWidget {
  const _CreateChooser();

  @override
  Widget build(BuildContext context) {
    final options = [
      (ContentType.blog, 'Write detailed articles with rich content and code snippets'),
      (ContentType.video, 'Upload long-form educational videos'),
      (ContentType.reel, 'Upload short engaging clips'),
      (ContentType.repo, 'Share your open-source projects'),
      (ContentType.image, 'Upload images, diagrams or drawings'),
      (ContentType.podcast, 'Recorded sessions will be saved as draft'),
    ];
    return FlowSheetFrame(
      title: 'Create Content',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (type, text) in options)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassOption(
                height: 68,
                radius: 18,
                selected: false,
                onTap: () => Navigator.of(context).pop(type),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      GlassIconBadge(icon: typeIcon(type), size: 42),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _typeName(type),
                              style: AppText.label.copyWith(fontSize: 14.5, fontWeight: FontWeight.w700),
                            ),
                            Text(text, style: AppText.caption.copyWith(fontSize: 11.5)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: Colors.white),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnalyticsSheet extends StatelessWidget {
  const _AnalyticsSheet({required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    final service = ContentService.instance;
    return FlowSheetFrame(
      title: 'Analytics',
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final appreciations = item.appreciatedBy.length;
          final comments = item.comments.length;
          final saves = service.savesOf(item);
          final rate = item.views == 0 ? 0 : ((appreciations + comments + saves) / item.views * 100);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item.title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              Text(
                item.draft ? 'Draft · not visible to seekers' : 'Published ${formatDay(item.createdAt)}',
                style: AppText.caption,
              ),
              gap14,
              OptionGrid(
                columns: 2,
                spacing: 8,
                children: [
                  _Metric('Views', compact(item.views), Icons.visibility_outlined),
                  _Metric.clap('Appreciations', '$appreciations'),
                  _Metric('Comments', '$comments', Icons.chat_bubble_outline_rounded),
                  _Metric('Saves', '$saves', Icons.bookmark_border_rounded),
                ],
              ),
              gap8,
              GlassWell(
                radius: 16,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.trending_up_rounded, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Engagement rate', style: AppText.label.copyWith(fontSize: 14))),
                    Text(
                      '${rate.toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                  ],
                ),
              ),
              gap14,
              const Text(
                'Recent comments',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              gap8,
              if (item.comments.isEmpty)
                Text('No comments yet.', style: AppText.caption)
              else
                for (final c in item.comments.reversed.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GlassWell(
                      radius: 14,
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${c.author} · ${ago(c.at)}', style: AppText.caption.copyWith(fontSize: 11.5)),
                          const SizedBox(height: 2),
                          Text(c.text, style: AppText.label.copyWith(fontSize: 13.5)),
                        ],
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, IconData this.icon);

  /// Appreciations, shown as claps.
  const _Metric.clap(this.label, this.value) : icon = null;

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          if (icon case final icon?) Icon(icon, size: 20, color: Colors.white) else const ClapIcon(size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                Text(label, style: AppText.caption.copyWith(fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmDelete extends StatelessWidget {
  const _ConfirmDelete({required this.item});

  final ContentItem item;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Delete content?',
      body: Text(
        '"${item.title}" will be removed for everyone, with its views, appreciations and comments. '
        'This can\'t be undone.',
        style: AppText.body,
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Delete', onPressed: () => Navigator.of(context).pop(true)),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.section, required this.onCreate});

  final _Section section;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final text = switch (section) {
      _Section.home => 'Nothing published yet. Create your first piece of content.',
      _Section.premium => 'No premium content yet. Mark 3D animated videos or reels as Premium when you create them.',
      _Section.free => 'No free content yet.',
      _Section.drafts => 'No drafts. Content you save without publishing appears here.',
      _Section.podcasts => 'No recorded podcasts yet. Recordings from your podcast sessions appear here as drafts.',
    };
    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          GlassIconBadge(icon: section.icon, size: 64),
          gap14,
          Text(text, style: AppText.body, textAlign: TextAlign.center),
          if (section != _Section.podcasts) ...[
            gap14,
            SmallPillButton(label: '+ Create Content', primary: true, onPressed: onCreate),
          ],
        ],
      ),
    );
  }
}

// ---- Create / edit form -----------------------------------------------------------------

/// One form for every type the solver creates, and for editing. Fields follow
/// the type: an upload for videos, reels and images, a repository link for
/// repos, and the Visual/HTML editor for blogs.
class ContentFormSheet extends StatefulWidget {
  const ContentFormSheet({super.key, required this.user, required this.type, this.item});

  final AppUser user;
  final ContentType type;

  /// Set when editing.
  final ContentItem? item;

  @override
  State<ContentFormSheet> createState() => _ContentFormSheetState();
}

class _ContentFormSheetState extends State<ContentFormSheet> {
  static const _maxMedia = 5 * 1024 * 1024 * 1024;
  static const _videoExtensions = ['mp4', 'webm', 'mov'];
  static const _imageExtensions = ['png', 'jpg', 'jpeg', 'svg', 'webp', 'gif', 'excalidraw'];

  late final _item = widget.item;
  late final _title = TextEditingController(text: _item?.title);
  late final _repo = TextEditingController(text: _item?.repoUrl);
  late final _description = TextEditingController(text: widget.type == ContentType.repo ? _item?.description : null);
  late final _body = TextEditingController(text: _item?.html ?? false ? _item!.body.join('\n') : null);
  final _tagInput = TextEditingController();
  late final _tags = List.of(_item?.tags ?? const <String>[]);
  late String? _category = _item?.category;
  late String? _subcategory = _item?.subcategory;
  late String? _format = _item?.format;
  late bool _premium = _item?.premium ?? false;
  late bool _publish = _item == null ? true : !_item.draft;
  bool _html = false;
  String? _coverPath;
  String? _coverName;
  String? _mediaPath;
  String? _mediaName;
  final _errors = <String, String?>{};
  String? _error;
  bool _saving = false;

  ContentType get _type => widget.type;
  bool get _hasUpload => _type == ContentType.video || _type == ContentType.reel || _type == ContentType.image;

  /// Premium is for high-quality (3D animated) videos and reels.
  bool get _canBePremium => _isVideo && _format == ContentService.premiumFormat;

  bool get _isVideo => _type == ContentType.video || _type == ContentType.reel;

  final _verification = SkillVerificationService.instance;

  @override
  void initState() {
    super.initState();
    // Categories are the solver's verified skills; their focus areas are the
    // sub-categories.
    _verification.addListener(_onVerification);
    if (!_verification.isLoaded(widget.user)) _verification.load(widget.user).catchError((Object _) {});
    _loadBlog();
    // Whether the server lets this solver publish, for the publish switch.
    ContentService.instance.loadPublishEligibility(widget.user).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Whether the blog being edited is still being fetched.
  bool _loadingBody = false;

  /// The solver's content list has no blog text; editing one fetches it so
  /// the editor opens with the blog as written.
  Future<void> _loadBlog() async {
    final item = _item;
    if (item == null || item.type != ContentType.blog || !item.remote || item.body.isNotEmpty) return;
    _loadingBody = true; // set before the first build
    await ContentService.instance.open(widget.user, item);
    if (!mounted) return;
    setState(() {
      _loadingBody = false;
      // Unless the solver has started typing meanwhile.
      if (_body.text.isEmpty && item.body.isNotEmpty) _body.text = item.body.join('\n');
    });
  }

  void _onVerification() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _verification.removeListener(_onVerification);
    for (final c in [_title, _repo, _description, _body, _tagInput]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Verified skills with their focus areas. Content being edited keeps the
  /// category and sub-category it already has.
  Map<String, List<String>> get _categories {
    final map = {for (final e in _verification.verifiedCategories(widget.user).entries) e.key: List.of(e.value)};
    final category = _item?.category;
    final sub = _item?.subcategory;
    if (category != null && category.isNotEmpty) {
      final subs = map.putIfAbsent(category, () => []);
      if (sub != null && sub.isNotEmpty && !subs.contains(sub)) subs.add(sub);
    }
    return map;
  }

  /// Why there's no category to choose, if there isn't.
  String get _noCategories => !_verification.isLoaded(widget.user)
      ? (_verification.loadError ?? 'Loading your verified skills...')
      : 'Verify a skill in Skill Verification to choose a category.';

  /// The largest cover the server accepts.
  static const _maxCover = 5 * 1024 * 1024;

  Future<void> _pickCover() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    if (bytes != null && bytes > _maxCover) {
      setState(() => _error = 'That cover is over 5 MB. Choose a smaller picture.');
      return;
    }
    setState(() {
      _coverPath = file.path;
      _coverName = file.name;
    });
  }

  Future<void> _pickMedia() async {
    final allowed = _type == ContentType.image ? _imageExtensions : _videoExtensions;
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: allowed);
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    setState(() {
      if (!allowed.contains(file.extension?.toLowerCase())) {
        _errors['media'] = 'Use one of: ${allowed.map((e) => e.toUpperCase()).join(', ')}.';
      } else if (bytes == null) {
        _errors['media'] = 'Couldn\'t read that file. Try another one.';
      } else if (bytes > _maxMedia) {
        _errors['media'] = 'That file is over 5 GB. Choose a smaller one.';
      } else {
        _mediaPath = file.path;
        _mediaName = file.name;
        _errors['media'] = null;
      }
    });
  }

  /// A picture being uploaded into the blog.
  bool _uploadingImage = false;

  static const _blogImageTypes = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif'];
  static const _maxBlogImage = 8 * 1024 * 1024;

  /// Uploads a picture and adds it to the blog where the cursor is. It's
  /// stored on the server, so readers see it on their own devices.
  Future<void> _insertImage() async {
    if (_uploadingImage) return;
    // Where the picture goes, kept while the picker is open.
    final selection = _body.selection;
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: _blogImageTypes);
    if (file == null || !mounted) return;
    final extension = (file.extension ?? file.name.split('.').last).toLowerCase();
    final bytes = await file.length();
    if (!mounted) return;
    final path = file.path;
    final problem = !_blogImageTypes.contains(extension)
        ? 'Add a PNG, JPG, GIF, WebP or AVIF picture.'
        : bytes != null && bytes > _maxBlogImage
        ? 'That picture is over 8 MB. Choose a smaller one.'
        : path == null
        ? 'Couldn\'t read that picture. Try another one.'
        : null;
    if (problem != null) {
      setState(() => _errors['body'] = problem);
      return;
    }
    setState(() {
      _uploadingImage = true;
      _errors['body'] = null;
    });
    try {
      final url = await ContentApi.uploadBlogImage(path: path!, fileName: file.name);
      if (!mounted) return;
      if (selection.isValid) _body.selection = selection;
      _wrap('<img src="$url">', '');
    } on AuthException catch (e) {
      if (mounted) setState(() => _errors['body'] = e.message);
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  void _wrap(String open, String close) {
    final text = _body.text;
    var selection = _body.selection;
    if (!selection.isValid) selection = TextSelection.collapsed(offset: text.length);
    final selected = selection.textInside(text);
    _body.value = TextEditingValue(
      text: selection.textBefore(text) + open + selected + close + selection.textAfter(text),
      selection: TextSelection.collapsed(offset: selection.start + open.length + selected.length),
    );
    setState(() => _errors['body'] = null);
  }

  void _addTag() {
    final tag = _tagInput.text.trim().replaceAll(RegExp(r'^#+'), '');
    if (tag.isEmpty) return;
    setState(() {
      if (!_tags.any((t) => t.toLowerCase() == tag.toLowerCase())) _tags.add(tag);
      _tagInput.clear();
      _errors['tags'] = null;
    });
  }

  Future<void> _pick(String title, List<String> options, String? current, ValueChanged<String> onPicked) async {
    final picked = await showGlassPicker(context, title: title, options: options, label: (s) => s, selected: current);
    if (picked != null) onPicked(picked);
  }

  static String _plain(String html) => html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<void> _save() async {
    if (_saving) return;
    final repo = _repo.text.trim();
    final repoUri = Uri.tryParse(repo);
    setState(() {
      _error = null;
      _errors
        ..['title'] = _title.text.trim().length < 5 ? 'Use at least 5 characters.' : null
        ..['category'] = _category == null ? 'Select a category.' : null
        ..['sub'] = _subcategory == null ? 'Select a sub-category.' : null
        ..['format'] = _format == null ? 'Select a format.' : null
        ..['tags'] = _tags.isEmpty ? 'Add at least one tag.' : null
        ..['media'] = _hasUpload && _mediaPath == null && _item?.mediaFileName == null && _item == null
            ? 'Upload a file.'
            : _errors['media']
        ..['repo'] = _type != ContentType.repo
            ? null
            : repoUri == null ||
                  repoUri.host != 'github.com' ||
                  repoUri.pathSegments.where((s) => s.isNotEmpty).length < 2
            ? 'Enter a link like https://github.com/username/repository'
            : null
        ..['body'] = _type == ContentType.blog && _plain(_body.text).length < 50
            ? 'Write at least 50 characters.'
            : null;
    });
    if (_errors.values.any((e) => e != null)) {
      setState(() => _error = 'Check the highlighted fields.');
      return;
    }
    final description = switch (_type) {
      ContentType.repo => _description.text.trim(),
      ContentType.blog => _plain(_body.text),
      _ => '${_format!} · ${_subcategory!}',
    };
    final shortDescription = description.length > 180 ? '${description.substring(0, 177)}…' : description;
    final service = ContentService.instance;
    setState(() => _saving = true);
    try {
      if (_item == null) {
        await service.create(
          widget.user,
          type: _type,
          title: _title.text,
          description: shortDescription,
          category: _category!,
          subcategory: _subcategory!,
          format: _format!,
          tags: _tags,
          premium: _canBePremium && _premium,
          publish: _publish,
          coverPath: _coverPath,
          mediaPath: _type == ContentType.image ? _mediaPath : null,
          mediaFileName: _mediaName,
          repoUrl: _type == ContentType.repo ? repo : null,
          htmlBody: _type == ContentType.blog ? _body.text : null,
          uploadPath: _hasUpload ? _mediaPath : null,
        );
      } else {
        await service.update(
          widget.user,
          _item,
          title: _title.text,
          description: shortDescription,
          category: _category!,
          subcategory: _subcategory!,
          format: _format!,
          tags: _tags,
          premium: _canBePremium && _premium,
          publish: _publish,
          coverPath: _coverPath,
          // A new file replaces the current one.
          mediaPath: _hasUpload ? _mediaPath : null,
          mediaFileName: _mediaName,
          repoUrl: _type == ContentType.repo ? repo : null,
          htmlBody: _type == ContentType.blog ? _body.text : null,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPublish = ContentService.instance.canPublish(widget.user);
    final categories = _categories;
    final subs = _category == null ? const <String>[] : categories[_category] ?? const <String>[];
    final existingCover = _item?.coverPath != null ? 'Current cover kept' : null;
    return FlowSheetFrame(
      title: '${_item == null ? 'Create' : 'Edit'} ${_typeName(_type)}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          // Cover
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const GlassIconBadge(icon: Icons.image_outlined, size: 52),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Add cover', style: _label),
                      Text(
                        _coverName ?? existingCover ?? 'Recommended - shown on feed cards. PNG/JPG/WebP.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(fontSize: 11.5),
                      ),
                      const SizedBox(height: 6),
                      SmallPillButton(label: 'Choose image', onPressed: _pickCover),
                    ],
                  ),
                ),
              ],
            ),
          ),
          gap14,
          if (_hasUpload) ...[
            const Text('Upload Files *', style: _label),
            gap8,
            GlassWell(
              radius: 18,
              error: _errors['media'] != null,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: _pickMedia,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
                    child: Column(
                      children: [
                        Icon(
                          _mediaName != null ? Icons.check_circle_outline_rounded : Icons.cloud_upload_outlined,
                          size: 30,
                          color: Colors.white,
                        ),
                        gap8,
                        Text(
                          _mediaName ?? _item?.mediaFileName ?? 'Tap to browse files',
                          textAlign: TextAlign.center,
                          style: AppText.label.copyWith(fontSize: 13.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          switch (_type) {
                            ContentType.image => 'PNG, JPG, SVG, WebP, GIF, or an Excalidraw drawing (.excalidraw)',
                            ContentType.reel => 'MP4, WebM, or MOV short clip (up to 5GB)',
                            _ => 'MP4, WebM, or MOV video (up to 5GB)',
                          },
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            FieldError(_errors['media']),
            gap14,
          ],
          if (_type == ContentType.repo) ...[
            const Text('GitHub Repository URL *', style: _label),
            gap8,
            GlassTextField(
              controller: _repo,
              hint: 'https://github.com/username/repository',
              icon: Icons.link_rounded,
              keyboardType: TextInputType.url,
              errorText: _errors['repo'],
              onChanged: (_) => setState(() => _errors['repo'] = null),
            ),
            gap14,
            const Text('Description', style: _label),
            gap8,
            GlassTextField(
              controller: _description,
              hint: 'Describe what this repository contains, how to run it, key features…',
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            gap14,
          ],
          const Text('Title *', style: _label),
          gap8,
          GlassTextField(
            controller: _title,
            hint: 'Enter content title...',
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['title'],
            onChanged: (_) => setState(() => _errors['title'] = null),
          ),
          gap14,
          const Text('Category *', style: _label),
          gap8,
          GlassSelectField(
            value: _category,
            hint: 'Select category...',
            errorText: _errors['category'],
            onTap: categories.isEmpty
                ? () => setState(() => _errors['category'] = _noCategories)
                : () => _pick('Category', categories.keys.toList(), _category, (v) {
                    setState(() {
                      if (v != _category) _subcategory = null;
                      _category = v;
                      _errors['category'] = null;
                    });
                  }),
          ),
          gap14,
          const Text('Sub-Category *', style: _label),
          gap8,
          GlassSelectField(
            value: _subcategory,
            hint: _category == null ? 'Select a category first' : 'Select sub-category...',
            errorText: _errors['sub'],
            locked: _category == null,
            onTap: _category == null
                ? null
                : subs.isEmpty
                ? () => setState(() => _errors['sub'] = 'No focus areas are verified for $_category yet.')
                : () => _pick('Sub-Category', subs, _subcategory, (v) {
                    setState(() {
                      _subcategory = v;
                      _errors['sub'] = null;
                    });
                  }),
          ),
          gap14,
          const Text('Format *', style: _label),
          gap8,
          GlassSelectField(
            value: _format,
            hint: 'Select format...',
            errorText: _errors['format'],
            // Set when it's created; the server doesn't change it afterwards.
            locked: _item != null,
            onTap: _item != null
                ? null
                : () => _pick('Format', ContentService.formats, _format, (v) {
                    setState(() {
                      _format = v;
                      _errors['format'] = null;
                    });
                  }),
          ),
          gap14,
          GlassWell(
            radius: 16,
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Publish immediately after upload', style: AppText.label.copyWith(fontSize: 13.5)),
                      Text(
                        canPublish
                            ? 'Otherwise saved as Draft - click Publish on the card later'
                            : ContentService.instance.publishBlockedReason(widget.user),
                        style: AppText.caption.copyWith(fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _publish && canPublish,
                  onChanged: canPublish ? (v) => setState(() => _publish = v) : null,
                  thumbColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.white(0.8),
                  ),
                  trackColor: WidgetStateProperty.resolveWith(
                    (s) => s.contains(WidgetState.selected) ? Colors.white : AppColors.white(0.14),
                  ),
                  trackOutlineColor: WidgetStateProperty.all(AppColors.white(0.3)),
                ),
              ],
            ),
          ),
          if (_type == ContentType.blog) ...[gap14, _blogEditor()],
          gap14,
          const Text('Tags (Hashtags) *', style: _label),
          gap8,
          Row(
            children: [
              Expanded(
                child: GlassTextField(
                  controller: _tagInput,
                  hint: 'Type a tag and press Enter...',
                  icon: Icons.tag_rounded,
                  textInputAction: TextInputAction.done,
                  errorText: _errors['tags'],
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 8),
              SmallPillButton(label: 'Add', onPressed: _addTag),
            ],
          ),
          if (_tags.isNotEmpty) ...[
            gap8,
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in _tags)
                  GlassChip(label: '#$t  ✕', selected: false, onTap: () => setState(() => _tags.remove(t))),
              ],
            ),
          ],
          gap14,
          const Text('Content Access', style: _label),
          gap8,
          GlassSelectField(
            value: _canBePremium && _premium ? 'Premium - subscribers only' : 'Free - open to any authenticated viewer',
            hint: 'Access tier',
            locked: !_canBePremium,
            onTap: !_canBePremium
                ? null
                : () => _pick(
                    'Access tier',
                    const ['Free - open to any authenticated viewer', 'Premium - subscribers only'],
                    _premium ? 'Premium - subscribers only' : 'Free - open to any authenticated viewer',
                    (v) => setState(() => _premium = v.startsWith('Premium')),
                  ),
          ),
          if (!_canBePremium) ...[
            const SizedBox(height: 6),
            Text(
              _isVideo && _item == null
                  ? 'Premium is only for 3D animated videos and reels. Choose the ${ContentService.premiumFormat} '
                        'format to offer it.'
                  : 'Premium is only for 3D animated videos and reels.',
              style: AppText.caption.copyWith(fontSize: 11.5),
            ),
          ],
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(
              label: _publish && canPublish ? 'Publish Content' : 'Save as Draft',
              loading: _saving,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }

  Widget _blogEditor() {
    final tools = <(IconData, String, VoidCallback)>[
      (Icons.format_bold_rounded, 'Bold', () => _wrap('<b>', '</b>')),
      (Icons.format_italic_rounded, 'Italic', () => _wrap('<i>', '</i>')),
      (Icons.format_underlined_rounded, 'Underline', () => _wrap('<u>', '</u>')),
      (Icons.link_rounded, 'Link', () => _wrap('<a href="https://">', '</a>')),
      (_uploadingImage ? Icons.hourglass_top_rounded : Icons.image_outlined, 'Image', _insertImage),
      (Icons.code_rounded, 'Code', () => _wrap('<pre>', '</pre>')),
      (Icons.format_list_bulleted_rounded, 'List', () => _wrap('<ul>\n<li>', '</li>\n</ul>')),
      (Icons.title_rounded, 'Heading', () => _wrap('<h2>', '</h2>')),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Blog Content *', style: _label),
        gap8,
        Row(
          children: [
            for (final (html, label) in const [(false, 'Visual'), (true, 'HTML')]) ...[
              if (html) const SizedBox(width: 8),
              Expanded(
                child: GlassOption(
                  height: 40,
                  radius: 14,
                  selected: _html == html,
                  onTap: () => setState(() => _html = html),
                  child: Text(label, style: AppText.label.copyWith(fontSize: 13.5)),
                ),
              ),
            ],
          ],
        ),
        gap8,
        Text(
          'Format with the toolbar, or switch to HTML to paste code. Add pictures anywhere in the article with the '
          'image button. Either way it renders for readers exactly as written.',
          style: AppText.caption.copyWith(fontSize: 11.5),
        ),
        gap8,
        if (!_html) ...[
          GlassWell(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Wrap(
              alignment: WrapAlignment.spaceAround,
              children: [
                for (final (icon, tip, onTap) in tools)
                  IconButton(
                    tooltip: tip,
                    visualDensity: VisualDensity.compact,
                    onPressed: onTap,
                    icon: Icon(icon, size: 20, color: Colors.white),
                  ),
              ],
            ),
          ),
          gap8,
        ],
        GlassTextField(
          controller: _body,
          hint: _loadingBody
              ? 'Loading your blog…'
              : _html
              ? '<h2>Title</h2>\n<p>Paste or write HTML…</p>'
              : 'Write your blog content...',
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          errorText: _errors['body'],
          onChanged: (_) => setState(() => _errors['body'] = null),
        ),
        if (_body.text.trim().isNotEmpty) ...[
          gap8,
          Text('Preview', style: AppText.caption.copyWith(fontSize: 12)),
          gap8,
          GlassWell(radius: 16, padding: const EdgeInsets.all(14), child: HtmlText(_body.text)),
        ],
      ],
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}
