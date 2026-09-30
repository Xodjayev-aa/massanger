import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/chat_repository.dart';
import '../../data/economy_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/media_cache.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';
import '../feed/video_tile.dart';

/// A creator's channel: the page behind every avatar and every `@handle`.
///
/// Three rules shape it. The tabs are the catalogue (long-form, reels, about),
/// the follow button is the only primary action, and a private account never
/// leaks its own counts before the follow request is accepted — the header
/// renders what the server returned and nothing more, so the UI cannot be
/// talked into showing a locked channel.
class UserPage extends StatefulWidget {
  const UserPage({super.key, required this.userId});

  final String userId;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  ProfileCard? _profile;
  List<VideoCard> _videos = const <VideoCard>[];
  List<TagSummary> _videoTags = const <TagSummary>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;
  String? _error;
  bool _busy = false;

  bool get _isMe => _profile?.id == sl<SocialRepository>().currentUserId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final social = sl<SocialRepository>();
      final profile = await social.profile(widget.userId);
      if (!mounted) return;
      if (profile == null) {
        setState(() {
          _loading = false;
          _error = 'That channel is not available.';
        });
        return;
      }
      final videos = await sl<FeedRepository>().authorVideos(profile.id, limit: 24);
      // One batched tag lookup covers the channel owner and every video author
      // on the grid, so the header and the tiles agree on what a tag looks like.
      final tags = await social.tagsFor(<String>{profile.id, ...videos.map((v) => v.authorId)});
      if (!mounted) return;
      final wanted = tags[profile.id] ?? const <TagSummary>[];
      setState(() {
        _profile = profile.copyWith(tags: wanted);
        _videos = videos;
        _videoTags = wanted;
        _exhausted = videos.length < 24;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'That channel could not be loaded.';
      });
    }
  }

  Future<void> _loadMore() async {
    final profile = _profile;
    if (profile == null || _loadingMore || _exhausted || _videos.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final last = _videos.last;
      final more = await sl<FeedRepository>().authorVideos(
        profile.id,
        beforeAt: last.publishedAt,
        beforeId: last.id,
        limit: 24,
      );
      if (!mounted) return;
      setState(() {
        _videos = <VideoCard>[..._videos, ...more];
        _exhausted = more.length < 24;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _toggleFollow() async {
    final profile = _profile;
    if (profile == null || _busy) return;
    setState(() => _busy = true);
    try {
      final social = sl<SocialRepository>();
      if (profile.isFollowing || profile.followState == 'pending') {
        await social.unfollow(profile.id);
        if (mounted) {
          setState(() => _profile = profile.copyWith(
                isFollowing: false,
                followState: 'none',
                followerCount: (profile.followerCount - 1).clamp(0, 1 << 30),
              ));
        }
      } else {
        // `requested` means the account is private: the button must say
        // "Requested" rather than claim a follow that has not been accepted.
        final state = await social.follow(userId: profile.id);
        if (mounted) {
          setState(() => _profile = profile.copyWith(
                isFollowing: state == 'accepted',
                followState: state,
                followerCount: profile.followerCount + (state == 'accepted' ? 1 : 0),
              ));
        }
      }
    } on AppException catch (error) {
      _toast(error.message);
    } catch (_) {
      _toast('That did not go through. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _message() async {
    final profile = _profile;
    if (profile == null) return;
    try {
      final chatId = await sl<ChatRepository>().createDirectChat(peerId: profile.id);
      if (mounted) context.push(Routes.chat(chatId));
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _tip() async {
    final profile = _profile;
    if (profile == null) return;
    final amount = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _TipSheet(name: profile.displayName ?? profile.username),
    );
    if (amount == null) return;
    try {
      await sl<EconomyRepository>().sendGift(recipientId: profile.id, stars: amount, kind: 'tip');
      _toast('Sent $amount Stars to ${profile.username}.');
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _block() async {
    final profile = _profile;
    if (profile == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Block @${profile.username}?'),
        content: const Text('They will not be able to follow you or message you, and their videos leave your feeds.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Block')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await sl<SocialRepository>().block(profile.id);
      _toast('Blocked @${profile.username}. Manage blocks in Settings.');
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : profile == null
              ? _Failure(message: _error ?? 'That channel is not available.', onRetry: _load)
              : NestedScrollView(
                  headerSliverBuilder: (context, innerScrolled) => <Widget>[
                    SliverAppBar(
                      pinned: true,
                      expandedHeight: 168,
                      actions: <Widget>[
                        if (!_isMe)
                          IconButton(
                            tooltip: 'Copy link',
                            icon: const Icon(Icons.link_rounded),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: 'https://messengerx.app/u/${profile.id}'));
                              _toast('Link copied.');
                            },
                          ),
                        if (!_isMe)
                          PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'block') unawaited(_block());
                            },
                            itemBuilder: (context) => const <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(value: 'block', child: Text('Block account')),
                            ],
                          ),
                      ],
                      flexibleSpace: FlexibleSpaceBar(
                        background: _HeaderBackdrop(profile: profile),
                      ),
                    ),
                    SliverToBoxAdapter(child: _ChannelHeader(profile: profile, tags: _videoTags)),
                    SliverToBoxAdapter(
                      child: _ChannelActions(
                        profile: profile,
                        isMe: _isMe,
                        busy: _busy,
                        onFollow: _toggleFollow,
                        onMessage: _message,
                        onTip: _tip,
                        onEdit: () => context.push(Routes.settings),
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabBarDelegate(
                        TabBar(
                          controller: _tabs,
                          tabs: const <Widget>[
                            Tab(text: 'Videos'),
                            Tab(text: 'Reels'),
                            Tab(text: 'About'),
                          ],
                        ),
                      ),
                    ),
                  ],
                  body: TabBarView(
                    controller: _tabs,
                    children: <Widget>[
                      _VideoGrid(
                        videos: _videos,
                        authorTags: _videoTags,
                        loadingMore: _loadingMore,
                        onLoadMore: _loadMore,
                        emptyTitle: 'No videos yet',
                        emptyMessage: _isMe
                            ? 'Upload your first long-form video from the + button.'
                            : '${profile.username} has not published a long video yet.',
                      ),
                      _ReelGrid(authorId: profile.id),
                      _AboutTab(profile: profile),
                    ],
                  ),
                ),
    );
  }
}

/// The banner: blurred initials over the brand gradient. No network call, so a
/// channel with no banner still looks deliberate.
class _HeaderBackdrop extends StatelessWidget {
  const _HeaderBackdrop({required this.profile});

  final ProfileCard profile;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: Brand.gradient),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            profile.username.isEmpty ? 'channel' : '@${profile.username}',
            style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 0.4),
          ),
        ),
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({required this.profile, required this.tags});

  final ProfileCard profile;
  final List<TagSummary> tags;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = profile.name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              PersonAvatar(name: name, path: profile.avatarPath, size: 62),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    NameLine(
                      name: name,
                      verified: profile.verified,
                      tags: tags,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      handleOf(profile.username, profile.discriminator),
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (profile.bio != null && profile.bio!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(profile.bio!.trim(), style: const TextStyle(fontSize: 13.5, height: 1.35)),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _Stat(label: 'Followers', value: compactCount(profile.followerCount)),
              _Stat(label: 'Following', value: compactCount(profile.followingCount)),
              _Stat(label: 'Videos', value: compactCount(profile.postCount)),
              if (profile.isPrivate) const _Pill(icon: Icons.lock_rounded, label: 'Private'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChannelActions extends StatelessWidget {
  const _ChannelActions({
    required this.profile,
    required this.isMe,
    required this.busy,
    required this.onFollow,
    required this.onMessage,
    required this.onTip,
    required this.onEdit,
  });

  final ProfileCard profile;
  final bool isMe;
  final bool busy;
  final VoidCallback onFollow;
  final VoidCallback onMessage;
  final VoidCallback onTip;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: <Widget>[
          if (isMe)
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Edit profile'),
              ),
            )
          else ...<Widget>[
            Expanded(
              child: FollowButton(
                following: profile.isFollowing,
                pending: profile.followState == 'pending',
                onPressed: busy ? () {} : onFollow,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Message',
              onPressed: onMessage,
              icon: const Icon(Icons.chat_bubble_outline_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Send Stars',
              onPressed: onTip,
              icon: const Icon(Icons.star_outline_rounded),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          Text(label, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// The long-form catalogue, two columns, same tile as the home feed.
class _VideoGrid extends StatelessWidget {
  const _VideoGrid({
    required this.videos,
    required this.authorTags,
    required this.loadingMore,
    required this.onLoadMore,
    required this.emptyTitle,
    required this.emptyMessage,
  });

  final List<VideoCard> videos;
  final List<TagSummary> authorTags;
  final bool loadingMore;
  final VoidCallback onLoadMore;
  final String emptyTitle;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return EmptyState(title: emptyTitle, message: emptyMessage, icon: Icons.videocam_off_outlined);
    }
    final media = sl<MediaCache>();
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: 1.5,
      ),
      itemCount: videos.length + 1,
      itemBuilder: (context, index) {
        if (index == videos.length) {
          if (loadingMore) return const Center(child: CircularProgressIndicator());
          return Center(
            child: TextButton(onPressed: onLoadMore, child: const Text('Show more videos')),
          );
        }
        final video = videos[index];
        return VideoTile(
          video: video,
          media: media,
          tags: authorTags,
          onTap: () => context.push(Routes.watch(video.id)),
        );
      },
    );
  }
}

/// Reels for a channel, loaded from the shorts feed filtered by author.
class _ReelGrid extends StatefulWidget {
  const _ReelGrid({required this.authorId});

  final String authorId;

  @override
  State<_ReelGrid> createState() => _ReelGridState();
}

class _ReelGridState extends State<_ReelGrid> {
  List<ShortCard> _shorts = const <ShortCard>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final shorts = await sl<FeedRepository>().shorts(tab: 'profile', authorId: widget.authorId, limit: 30);
      if (mounted) setState(() {
        _shorts = shorts;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_shorts.isEmpty) {
      return const EmptyState(title: 'No reels yet', message: 'Short vertical videos show up here.', icon: Icons.smart_display_outlined);
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 0.62,
      ),
      itemCount: _shorts.length,
      itemBuilder: (context, index) => _ReelThumb(short: _shorts[index]),
    );
  }
}

class _ReelThumb extends StatefulWidget {
  const _ReelThumb({required this.short});

  final ShortCard short;

  @override
  State<_ReelThumb> createState() => _ReelThumbState();
}

class _ReelThumbState extends State<_ReelThumb> {
  String? _url;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final key = widget.short.thumbnailKey;
    if (key == null) return;
    final url = await sl<MediaCache>().url(key);
    if (mounted) setState(() => _url = url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => context.push(Routes.shortWatch(widget.short.id)),
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_url != null)
              Image.network(_url!, fit: BoxFit.cover, errorBuilder: (context, error, stack) => ColoredBox(color: scheme.surfaceContainerHighest))
            else
              ColoredBox(color: scheme.surfaceContainerHighest, child: const Icon(Icons.play_arrow_rounded)),
            Positioned(
              left: 6,
              bottom: 6,
              child: Row(
                children: <Widget>[
                  const Icon(Icons.play_arrow_rounded, size: 14, color: Colors.white),
                  const SizedBox(width: 2),
                  Text(
                    compactCount(widget.short.viewCount),
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Everything a channel page owes the viewer: who this is, what they made, and
/// where the money goes.
class _AboutTab extends StatelessWidget {
  const _AboutTab({required this.profile});

  final ProfileCard profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      ('Handle', handleOf(profile.username, profile.discriminator)),
      ('Account', profile.accountKind.replaceAll('_', ' ')),
      ('Followers', compactCount(profile.followerCount)),
      ('Following', compactCount(profile.followingCount)),
      ('Videos', compactCount(profile.postCount)),
      ('Privacy', profile.isPrivate ? 'Private — follows need approval' : 'Public'),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      children: <Widget>[
        if (profile.bio != null && profile.bio!.trim().isNotEmpty) ...<Widget>[
          Text('About', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(profile.bio!.trim(), style: const TextStyle(fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 18),
        ],
        Text('Details', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: Text(row.$1, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
                Text(row.$2, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        const SizedBox(height: 18),
        Text('Tips', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          'Gifts and tips are paid in Stars. Nothing here is required to watch, follow or comment.',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4),
        ),
      ],
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            EmptyState(title: 'Nothing to show', message: message, icon: Icons.person_off_outlined),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: tabBar);
  }

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => oldDelegate.tabBar != tabBar;
}

/// Sending Stars to a creator. Five taps, no typing required, and the amount is
/// the only thing that comes back — the wallet RPC is what actually moves money.
class _TipSheet extends StatefulWidget {
  const _TipSheet({required this.name});

  final String name;

  @override
  State<_TipSheet> createState() => _TipSheetState();
}

class _TipSheetState extends State<_TipSheet> {
  static const List<int> _presets = <int>[10, 50, 100, 500];
  int _amount = 50;
  final TextEditingController _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Send Stars to ${widget.name}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Stars are the in-app currency. Creators keep the whole tip; nothing is taken out of it.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final preset in _presets)
                ChoiceChip(
                  label: Text('$preset ★'),
                  selected: _amount == preset && _custom.text.trim().isEmpty,
                  onSelected: (_) => setState(() {
                    _amount = preset;
                    _custom.clear();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _custom,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Or type an amount', hintText: '250'),
            onChanged: (value) {
              final parsed = int.tryParse(value.trim());
              setState(() => _amount = parsed ?? 0);
            },
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _amount > 0 ? () => Navigator.of(context).pop(_amount) : null,
            icon: const Icon(Icons.star_rounded, size: 18),
            label: Text(_amount > 0 ? 'Send $_amount Stars' : 'Choose an amount'),
          ),
        ],
      ),
    );
  }
}
