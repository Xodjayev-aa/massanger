import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/feed_repository.dart';
import '../../data/media_cache.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';
import '../feed/video_tile.dart';

/// One search box over the whole product: people, videos, reels, communities,
/// channels and sounds. `search_all` (00028) answers in a single round trip
/// because a search that fires six queries per keystroke is how a free tier
/// runs out of budget.
class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key});

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  late final TabController _tabs = TabController(length: 5, vsync: this);
  Timer? _debounce;

  SearchResults? _results;
  String? _query;
  String _typed = '';
  bool _searching = false;
  Object? _error;
  List<VideoCategory> _suggestedCategories = const <VideoCategory>[];
  List<({String tag, int useCount, int recentCount})> _trending = const <({String tag, int useCount, int recentCount})>[];

  @override
  void initState() {
    super.initState();
    unawaited(_discover());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// The empty state is not a blank page: it is what people browse when they
  /// have nothing to type.
  Future<void> _discover() async {
    try {
      final feed = sl<FeedRepository>();
      final categories = await feed.categories();
      final trending = await feed.trendingHashtags(limit: 18);
      if (!mounted) return;
      setState(() {
        _suggestedCategories = categories;
        _trending = trending;
      });
    } catch (_) {
      // Browsing aids are decoration; the search box still works.
    }
  }

  void _onChanged(String value) {
    setState(() => _typed = value);
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _query = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () => unawaited(_run(query)));
  }

  Future<void> _run(String query) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await sl<SocialRepository>().search(query);
      if (!mounted || _typed.trim() != query) return;
      setState(() {
        _results = results;
        _query = query;
        _searching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (value) {
            final query = value.trim();
            if (query.isNotEmpty) unawaited(_run(query));
          },
          decoration: InputDecoration(
            hintText: 'Search people, videos, reels, bots…',
            border: InputBorder.none,
            suffixIcon: _typed.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
        ),
        actions: <Widget>[
          if (_searching)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
        ],
        bottom: results == null
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: <Widget>[
                  Tab(text: 'Top'),
                  Tab(text: 'People'),
                  Tab(text: 'Videos'),
                  Tab(text: 'Reels'),
                  Tab(text: 'More'),
                ],
              ),
      ),
      body: results == null
          ? _DiscoverBody(categories: _suggestedCategories, trending: _trending)
          : _error != null
              ? EmptyState(
                  title: 'Search failed',
                  message: _error is AppException ? (_error! as AppException).message : 'Try again in a moment.',
                  icon: Icons.search_off_rounded,
                )
              : TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    _TopTab(results: results, query: _query ?? ''),
                    _PeopleTab(people: results.people),
                    _VideosTab(videos: results.videos),
                    _ReelsTab(shorts: results.shorts),
                    _MoreTab(results: results),
                  ],
                ),
      bottomNavigationBar: results == null
          ? null
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                '${results.people.length + results.videos.length + results.shorts.length + results.communities.length + results.channels.length + results.sounds.length} '
                'results for “$_query”',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
    );
  }
}

class _DiscoverBody extends StatelessWidget {
  const _DiscoverBody({required this.categories, required this.trending});

  final List<VideoCategory> categories;
  final List<({String tag, int useCount, int recentCount})> trending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (categories.isNotEmpty) ...<Widget>[
          const Text('Browse', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final category in categories)
                ActionChip(
                  avatar: Text(category.emoji ?? '🎬', style: const TextStyle(fontSize: 14)),
                  label: Text('${category.label}  ${compactCount(category.videoCount)}'),
                  onPressed: () => context.push('/home?category=${category.slug}'),
                ),
            ],
          ),
          const SizedBox(height: 22),
        ],
        if (trending.isNotEmpty) ...<Widget>[
          const Text('Trending hashtags', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          for (final tag in trending)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: scheme.primary.withOpacity(0.12),
                child: const Text('#', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              title: Text('#${tag.tag}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${compactCount(tag.useCount)} videos · ${compactCount(tag.recentCount)} this week'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/home?tag=${tag.tag}'),
            ),
        ],
        if (categories.isEmpty && trending.isEmpty)
          const EmptyState(
            title: 'Search the whole app',
            message: 'People, videos, reels, communities, channels, sounds and bots.',
            icon: Icons.search_rounded,
          ),
      ],
    );
  }
}

class _TopTab extends StatelessWidget {
  const _TopTab({required this.results, required this.query});

  final SearchResults results;
  final String query;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    for (final person in results.people.take(3)) {
      tiles.add(_PersonRow(person: person));
    }
    for (final video in results.videos.take(4)) {
      tiles.add(VideoRowTile(video: video, media: sl<MediaCache>()));
    }
    for (final community in results.communities.take(3)) {
      tiles.add(
        ListTile(
          leading: CircleAvatar(child: Text(community.name.isEmpty ? '?' : community.name[0].toUpperCase())),
          title: Text(community.name),
          subtitle: Text('${compactCount(community.memberCount)} members'),
          onTap: () => context.push(Routes.community(community.id)),
        ),
      );
    }
    for (final sound in results.sounds.take(3)) {
      tiles.add(
        ListTile(
          leading: const Icon(Icons.music_note_rounded),
          title: Text(sound.title),
          subtitle: Text(sound.artist ?? 'Unknown'),
          onTap: () => context.push(Routes.sound(sound.id)),
        ),
      );
    }
    if (tiles.isEmpty) {
      return EmptyState(title: 'No matches for “$query”', message: 'Try a shorter word or check the spelling.', icon: Icons.search_off_rounded);
    }
    return ListView(children: tiles);
  }
}

class _PeopleTab extends StatelessWidget {
  const _PeopleTab({required this.people});

  final List<ProfileCard> people;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return const EmptyState(title: 'No people found', icon: Icons.person_search_rounded);
    }
    return ListView(
      children: <Widget>[for (final person in people) _PersonRow(person: person)],
    );
  }
}

class _VideosTab extends StatelessWidget {
  const _VideosTab({required this.videos});

  final List<VideoCard> videos;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return const EmptyState(title: 'No videos found', icon: Icons.videocam_off_outlined);
    }
    return ListView.builder(
      itemCount: videos.length,
      itemBuilder: (context, index) => VideoTile(video: videos[index], media: sl<MediaCache>()),
    );
  }
}

class _ReelsTab extends StatelessWidget {
  const _ReelsTab({required this.shorts});

  final List<ShortCard> shorts;

  @override
  Widget build(BuildContext context) {
    if (shorts.isEmpty) {
      return const EmptyState(title: 'No reels found', icon: Icons.movie_filter_outlined);
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: 9 / 16,
      ),
      itemCount: shorts.length,
      itemBuilder: (context, index) {
        final short = shorts[index];
        return GestureDetector(
          onTap: () => context.push(Routes.shortWatch(short.id)),
          child: _ReelThumb(short: short, media: sl<MediaCache>()),
        );
      },
    );
  }
}

class _ReelThumb extends StatefulWidget {
  const _ReelThumb({required this.short, required this.media});

  final ShortCard short;
  final MediaCache media;

  @override
  State<_ReelThumb> createState() => _ReelThumbState();
}

class _ReelThumbState extends State<_ReelThumb> {
  String? _url;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final url = await widget.media.url(widget.short.thumbnailKey ?? widget.short.key);
    if (mounted) setState(() => _url = url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: scheme.surfaceContainerHighest),
        if (_url != null)
          Image.network(
            _url!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          )
        else
          const Center(child: Icon(Icons.play_arrow_rounded, color: Colors.white70)),
        Positioned(
          left: 6,
          bottom: 6,
          child: Row(
            children: <Widget>[
              const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
              const SizedBox(width: 2),
              Text(
                compactCount(widget.short.viewCount),
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MoreTab extends StatelessWidget {
  const _MoreTab({required this.results});

  final SearchResults results;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        if (results.communities.isNotEmpty) ...<Widget>[
          const _SectionLabel('Communities'),
          for (final community in results.communities)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Brand.seed.withOpacity(0.15),
                child: Text(community.name.isEmpty ? '?' : community.name[0].toUpperCase()),
              ),
              title: Text(community.name),
              subtitle: Text('${compactCount(community.memberCount)} members'
                  '${community.isPublic ? '' : ' · private'}'),
              trailing: community.joined ? const Icon(Icons.check_rounded) : null,
              onTap: () => context.push(Routes.community(community.id)),
            ),
        ],
        if (results.channels.isNotEmpty) ...<Widget>[
          const _SectionLabel('Channels'),
          for (final channel in results.channels)
            ListTile(
              leading: const Icon(Icons.campaign_rounded),
              title: Text(channel.title),
              subtitle: Text('${compactCount(channel.subscriberCount)} subscribers'),
              onTap: () => context.push(Routes.chat(channel.chatId)),
            ),
        ],
        if (results.sounds.isNotEmpty) ...<Widget>[
          const _SectionLabel('Sounds'),
          for (final sound in results.sounds)
            ListTile(
              leading: const Icon(Icons.music_note_rounded),
              title: Text(sound.title),
              subtitle: Text(sound.isVoiceOver ? 'AI voice-over' : (sound.artist ?? 'Original sound')),
              onTap: () => context.push(Routes.sound(sound.id)),
            ),
        ],
        if (results.communities.isEmpty && results.channels.isEmpty && results.sounds.isEmpty)
          const EmptyState(title: 'Nothing else matched', icon: Icons.travel_explore_rounded),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person});

  final ProfileCard person;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: PersonAvatar(name: person.displayName ?? person.username, path: person.avatarPath, size: 44),
      title: NameLine(
        name: person.displayName ?? person.username,
        handle: handleOf(person.username, person.discriminator),
        tags: person.tags,
        verified: person.verified,
        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        person.bio?.isNotEmpty == true
            ? person.bio!
            : '${compactCount(person.followerCount)} followers · ${compactCount(person.postCount)} posts',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: FollowButton(
        following: person.isFollowing,
        pending: person.followState == 'pending',
        compact: true,
        onPressed: () async {
          final repo = sl<SocialRepository>();
          if (person.isFollowing) {
            await repo.unfollow(person.id).catchError((Object _) {});
          } else {
            await repo.follow(userId: person.id).catchError((Object _) {});
          }
        },
      ),
      onTap: () => context.push(Routes.user(person.id)),
    );
  }
}
