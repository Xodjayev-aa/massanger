import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../core/errors.dart';
import '../../data/feed_repository.dart';
import '../../data/media_cache.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../feed/video_tile.dart';

/// The home tab: a long-form feed with the two tabs every modern feed has —
/// **For You** (everything the algorithm can rank) and **Following** (only
/// people you follow) — plus the category chips YouTube puts under them.
///
/// The page owns its pagination per tab, so switching tabs never rewrites the
/// other list, and it fetches author tags for a whole page in one call instead
/// of one call per tile.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this, initialIndex: 0);
  final ScrollController _scroll = ScrollController();

  final List<VideoCard> _forYou = <VideoCard>[];
  final List<VideoCard> _following = <VideoCard>[];
  final Map<String, List<TagSummary>> _tags = <String, List<TagSummary>>{};

  List<VideoCategory> _categories = const <VideoCategory>[];
  String? _category;

  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;
  Object? _error;
  int _unread = 0;

  String get _tab => _tabs.index == 0 ? 'for_you' : 'following';
  List<VideoCard> get _items => _tabs.index == 0 ? _forYou : _following;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
    _scroll.addListener(_maybeLoadMore);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    setState(() {
      _exhausted = false;
      _error = null;
    });
    if (_items.isEmpty) {
      unawaited(_load(reset: true));
    } else {
      setState(() {});
    }
  }

  Future<void> _bootstrap() async {
    final feed = sl<FeedRepository>();
    try {
      final categories = await feed.categories();
      if (mounted) setState(() => _categories = categories);
    } catch (_) {
      // Chips are decoration; a failure must not stop the feed.
    }
    await _load(reset: true);
    unawaited(_loadUnread());
  }

  Future<void> _loadUnread() async {
    try {
      final unread = await sl<FeedRepository>().unreadNotifications();
      if (mounted) setState(() => _unread = unread);
    } catch (_) {
      // The bell simply stays quiet.
    }
  }

  Future<void> _load({required bool reset}) async {
    if (_loadingMore) return;
    final tab = _tab;
    setState(() {
      if (reset) {
        _loading = _items.isEmpty;
        _exhausted = false;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });

    final current = reset ? const <VideoCard>[] : List<VideoCard>.from(_items);
    final cursor = current.isEmpty ? null : current.last;
    try {
      final page = await sl<FeedRepository>().videos(
        tab: tab,
        category: _category,
        beforeAt: cursor?.publishedAt,
        beforeId: cursor?.id,
      );
      final tags = await _fetchTags(page);
      if (!mounted) return;
      setState(() {
        final target = tab == 'for_you' ? _forYou : _following;
        target
          ..clear()
          ..addAll(current)
          ..addAll(page);
        _tags.addAll(tags);
        _exhausted = page.length < FeedRepository.videoPageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// One round trip for every author on the page.
  Future<Map<String, List<TagSummary>>> _fetchTags(List<VideoCard> page) async {
    if (page.isEmpty) return const <String, List<TagSummary>>{};
    try {
      return await sl<SocialRepository>().tagsFor(page.map((v) => v.authorId));
    } catch (_) {
      return const <String, List<TagSummary>>{};
    }
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loadingMore || _exhausted) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 900) {
      unawaited(_load(reset: false));
    }
  }

  Future<void> _refresh() async {
    await _load(reset: true);
    unawaited(_loadUnread());
  }

  void _pickCategory(String? slug) {
    if (_category == slug) return;
    setState(() {
      _category = slug;
      _forYou.clear();
      _following.clear();
      _exhausted = false;
    });
    unawaited(_load(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scroll,
          slivers: <Widget>[
            SliverAppBar(
              pinned: true,
              floating: false,
              titleSpacing: 14,
              title: const BrandLockup(size: 27),
              actions: <Widget>[
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search_rounded),
                  onPressed: () => context.push('/search'),
                ),
                _NotificationBell(unread: _unread, onTap: () => context.push('/notifications')),
                const SizedBox(width: 4),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(104),
                child: Column(
                  children: <Widget>[
                    TabBar(
                      controller: _tabs,
                      isScrollable: false,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                      indicatorSize: TabBarIndicatorSize.label,
                      tabs: const <Widget>[Tab(text: 'For You'), Tab(text: 'Following')],
                    ),
                    if (_categories.isNotEmpty)
                      SizedBox(
                        height: 46,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          children: <Widget>[
                            _CategoryChip(label: 'All', selected: _category == null, onTap: () => _pickCategory(null)),
                            for (final category in _categories)
                              _CategoryChip(
                                label: category.emoji == null ? category.label : '${category.emoji} ${category.label}',
                                selected: _category == category.slug,
                                onTap: () => _pickCategory(category.slug),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_loading && _items.isEmpty)
              const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
            else if (_error != null && _items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  title: 'The feed could not load',
                  message: _error is AppException ? (_error! as AppException).message : 'Check your connection and retry.',
                  icon: Icons.cloud_off_rounded,
                  action: FilledButton(onPressed: () => _load(reset: true), child: const Text('Retry')),
                ),
              )
            else if (_items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  title: _tabs.index == 0 ? 'Nothing here yet' : 'Follow someone first',
                  message: _tabs.index == 0
                      ? 'The first videos published on this deployment will appear right here.'
                      : 'Videos from the people you follow show up in this tab. Find them in Search.',
                  icon: _tabs.index == 0 ? Icons.video_library_outlined : Icons.person_add_alt_1_rounded,
                  action: FilledButton(
                    onPressed: () => context.push('/search'),
                    child: const Text('Find people'),
                  ),
                ),
              )
            else ...<Widget>[
              SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 460,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 0.78,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final video = _items[index];
                    return VideoTile(
                      video: video,
                      media: sl<MediaCache>(),
                      tags: _tags[video.authorId] ?? const <TagSummary>[],
                    );
                  },
                  childCount: _items.length,
                ),
              ),
              if (_loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
                  ),
                )
              else if (_exhausted && _items.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 26),
                    child: Center(
                      child: Text(
                        'You are all caught up',
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Material(
          color: selected
              ? (isDark ? Colors.white : Colors.black87)
              : (isDark ? const Color(0xFF24262B) : const Color(0xFFF0F1F4)),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? (isDark ? Colors.black : Colors.white) : scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.unread, required this.onTap});

  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        IconButton(
          tooltip: 'Notifications',
          icon: const Icon(Icons.notifications_none_rounded),
          onPressed: onTap,
        ),
        if (unread > 0)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: Brand.accent, borderRadius: BorderRadius.circular(10)),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
              ),
            ),
          ),
      ],
    );
  }
}
