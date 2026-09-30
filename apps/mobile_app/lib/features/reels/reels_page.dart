import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/shell.dart';
import '../../core/errors.dart';
import '../../data/feed_repository.dart';
import '../../data/media_cache.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';

/// The reels tab: full-screen vertical shorts with the two tabs the product
/// promises — **For You** and **Following** — and native swipe physics.
///
/// Two decisions worth naming:
///   • only the visible reel has a live player, with its immediate neighbours
///     preloaded, because three simultaneous H.264 decoders is how a phone gets
///     hot in a minute;
///   • the bottom bar and the status bar slide away while you are swiping and
///     come back when you stop, which is the behaviour people know from TikTok
///     and the reason the shell exposes [NavChrome] at all.
class ReelsPage extends StatefulWidget {
  const ReelsPage({super.key, this.initialTab = 'for_you', this.authorId, this.soundId});

  /// Deep links can open the tab directly: `/reels?tab=following`.
  final String initialTab;

  /// `/reels?author=<uuid>` — one creator's shorts.
  final String? authorId;
  final String? soundId;

  @override
  State<ReelsPage> createState() => _ReelsPageState();
}

class _ReelsPageState extends State<ReelsPage> with SingleTickerProviderStateMixin {
  late TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTab == 'following' ? 1 : 0,
  );

  final PageController _pages = PageController();
  final List<ShortCard> _items = <ShortCard>[];
  final Map<String, List<TagSummary>> _tags = <String, List<TagSummary>>{};

  bool _loading = true;
  bool _loadingMore = false;
  bool _exhausted = false;
  bool _liked = false;
  Object? _error;
  int _index = 0;
  Timer? _chromeTimer;

  /// Captured once: a `dispose` may not look a widget up the tree, and the
  /// reels tab is the one screen that has to put the bar back when it leaves.
  ValueNotifier<bool>? _chrome;

  @override
  void initState() {
    super.initState();
    if (widget.authorId != null || widget.soundId != null) {
      // A single creator's/sound's list has no tabs to switch.
      _tabs.dispose();
      _tabs = TabController(length: 1, vsync: this);
    }
    _tabs.addListener(_onTabChanged);
    unawaited(_load(reset: true));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome = NavChrome.maybeOf(context);
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _pages.dispose();
    _chrome?.value = false;
    super.dispose();
  }

  String get _tab {
    if (widget.authorId != null) return 'profile';
    if (widget.soundId != null) return 'sound';
    return _tabs.index == 0 ? 'for_you' : 'following';
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    unawaited(_load(reset: true));
  }

  Future<void> _load({required bool reset}) async {
    if (_loadingMore) return;
    setState(() {
      if (reset) {
        _loading = _items.isEmpty;
        _exhausted = false;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });

    final current = reset ? const <ShortCard>[] : List<ShortCard>.from(_items);
    final cursor = current.isEmpty ? null : current.last;
    try {
      final page = await sl<FeedRepository>().shorts(
        tab: _tab,
        authorId: widget.authorId,
        soundId: widget.soundId,
        beforeAt: cursor?.createdAt,
        beforeId: cursor?.id,
      );
      final tags = page.isEmpty
          ? const <String, List<TagSummary>>{}
          : await sl<SocialRepository>().tagsFor(page.map((s) => s.authorId));
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(current)
          ..addAll(page);
        _tags.addAll(tags);
        _exhausted = page.length < FeedRepository.shortPageSize;
        _loading = false;
        _loadingMore = false;
        if (reset) _index = 0;
      });
      if (reset && _pages.hasClients) _pages.jumpToPage(0);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  /// The bar comes back a moment after the last swipe, so a burst of flings does
  /// not flash the chrome in and out.
  void _scheduleChromeRestore() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(const Duration(milliseconds: 900), () {
      _chrome?.value = false;
    });
  }

  Future<void> _toggleLike(int index) async {
    final short = _items[index];
    final nowLiked = !short.likedByMe;
    setState(() {
      _items[index] = short.copyWith(
        likedByMe: nowLiked,
        likeCount: math.max(0, short.likeCount + (nowLiked ? 1 : -1)),
      );
    });
    try {
      final confirmed = await sl<FeedRepository>().rateShort(short.id);
      if (!mounted) return;
      setState(() {
        _items[index] = _items[index].copyWith(likedByMe: confirmed);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _items[index] = short);
      _toast(error);
    }
  }

  Future<void> _toggleSave(int index) async {
    final short = _items[index];
    try {
      final saved = await sl<FeedRepository>().toggleSaveShort(short.id);
      if (!mounted) return;
      setState(() => _items[index] = short.copyWith(savedByMe: saved));
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _follow(int index) async {
    final short = _items[index];
    try {
      if (short.followedByMe) {
        await sl<SocialRepository>().unfollow(short.authorId);
      } else {
        await sl<SocialRepository>().follow(userId: short.authorId);
      }
      if (!mounted) return;
      setState(() => _items[index] = short.copyWith(followedByMe: !short.followedByMe));
    } catch (error) {
      _toast(error);
    }
  }

  void _toast(Object error) {
    if (!mounted) return;
    final message = error is AppException ? error.message : 'Something went wrong.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _share(int index) {
    final short = _items[index];
    unawaited(sl<FeedRepository>().shareShort(short.id));
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('Copy link'),
              subtitle: Text('messengerx.app/reels/${short.id}'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.people_alt_outlined),
              title: const Text('Send to a chat'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/chats');
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: const Text('Comments'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/watch/short/${short.id}');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final singleList = widget.authorId != null || widget.soundId != null;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification && notification.dragDetails != null) {
            _chrome?.value = true;
          } else if (notification is ScrollEndNotification) {
            _scheduleChromeRestore();
          }
          return false;
        },
        child: Stack(
          children: <Widget>[
            if (_loading && _items.isEmpty)
              const Center(child: CircularProgressIndicator(color: Colors.white))
            else if (_error != null && _items.isEmpty)
              EmptyState(
                title: 'Reels could not load',
                message: _error is AppException ? (_error! as AppException).message : 'Check your connection and retry.',
                icon: Icons.cloud_off_rounded,
                action: FilledButton(onPressed: () => _load(reset: true), child: const Text('Retry')),
              )
            else if (_items.isEmpty)
              EmptyState(
                title: widget.authorId != null ? 'No reels yet' : 'No reels here yet',
                message: 'Vertical videos under a minute long show up on this tab.',
                icon: Icons.movie_filter_outlined,
                action: FilledButton(
                  onPressed: () => context.go('/create?kind=short'),
                  child: const Text('Record one'),
                ),
              )
            else
              PageView.builder(
                controller: _pages,
                scrollDirection: Axis.vertical,
                itemCount: _items.length,
                onPageChanged: (index) {
                  setState(() => _index = index);
                  _scheduleChromeRestore();
                  if (index >= _items.length - 2 && !_exhausted) unawaited(_load(reset: false));
                },
                itemBuilder: (context, index) {
                  final short = _items[index];
                  return _ReelView(
                    key: ValueKey<String>(short.id),
                    short: short,
                    media: sl<MediaCache>(),
                    tags: _tags[short.authorId] ?? const <TagSummary>[],
                    active: index == _index,
                    index: index,
                    total: _items.length,
                    onLike: () => _toggleLike(index),
                    onSave: () => _toggleSave(index),
                    onShare: () => _share(index),
                    onFollow: () => _follow(index),
                    onComment: () => context.push('/watch/short/${short.id}'),
                    onProfile: () => context.push('/u/${short.authorId}'),
                  );
                },
              ),
            if (!singleList)
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _ReelTab(
                        label: 'Following',
                        selected: _tabs.index == 1,
                        onTap: () => _tabs.animateTo(1),
                      ),
                      const SizedBox(width: 22),
                      _ReelTab(
                        label: 'For You',
                        selected: _tabs.index == 0,
                        onTap: () => _tabs.animateTo(0),
                      ),
                      const SizedBox(width: 22),
                      IconButton(
                        tooltip: 'Search',
                        onPressed: () => context.push('/search'),
                        icon: const Icon(Icons.search_rounded, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loadingMore)
              Positioned(
                bottom: 26,
                left: 0,
                right: 0,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReelTab extends StatelessWidget {
  const _ReelTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 3),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 2.5,
            width: selected ? 22 : 0,
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(2))),
          ),
        ],
      ),
    );
  }
}

/// One reel: the player, the overlay, the rail and the info block.
class _ReelView extends StatefulWidget {
  const _ReelView({
    super.key,
    required this.short,
    required this.media,
    required this.tags,
    required this.active,
    required this.index,
    required this.total,
    required this.onLike,
    required this.onSave,
    required this.onShare,
    required this.onFollow,
    required this.onComment,
    required this.onProfile,
  });

  final ShortCard short;
  final MediaCache media;
  final List<TagSummary> tags;
  final bool active;
  final int index;
  final int total;
  final VoidCallback onLike;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onFollow;
  final VoidCallback onComment;
  final VoidCallback onProfile;

  @override
  State<_ReelView> createState() => _ReelViewState();
}

class _ReelViewState extends State<_ReelView> with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  String? _url;
  bool _ready = false;
  bool _paused = false;
  bool _muted = false;
  bool _viewRecorded = false;
  DateTime _enteredAt = DateTime.now();
  double _progress = 0;
  late final AnimationController _heart = AnimationController(vsync: this, duration: const Duration(milliseconds: 620));
  Offset? _heartAt;

  /// One id for the whole session with this reel, so a replay inside the visit
  /// is the same view and a return visit is a new one.
  final String _session = 'reel-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(_ReelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _enteredAt = DateTime.now();
        _viewRecorded = false;
        unawaited(_controller?.play());
        setState(() => _paused = false);
      } else {
        unawaited(_report());
        unawaited(_controller?.pause());
      }
    }
  }

  @override
  void dispose() {
    unawaited(_report());
    unawaited(_controller?.dispose());
    _heart.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final url = await widget.media.url(widget.short.key);
    if (!mounted || url == null) return;
    setState(() => _url = url);
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _ready = true;
      });
      if (widget.active) await controller.play();
      await _record();
    } catch (_) {
      await controller.dispose();
    }
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    final total = value.duration.inMilliseconds;
    final next = total == 0 ? 0.0 : (value.position.inMilliseconds / total).clamp(0.0, 1.0);
    // Rebuilding 30×/s for a progress bar would be wasteful; once per percent is
    // plenty for a 3-pixel line.
    if ((next - _progress).abs() > 0.01) {
      setState(() => _progress = next);
    }
  }

  Future<void> _record() async {
    if (_viewRecorded) return;
    _viewRecorded = true;
    try {
      await sl<FeedRepository>().recordShortView(shortId: widget.short.id, sessionId: _session);
    } catch (_) {
      // A view is telemetry; never surface it.
    }
  }

  Future<void> _report() async {
    if (!_viewRecorded) return;
    final watched = DateTime.now().difference(_enteredAt);
    final controller = _controller;
    final completed = controller != null &&
        controller.value.duration.inMilliseconds > 0 &&
        controller.value.position.inMilliseconds >= controller.value.duration.inMilliseconds - 250;
    try {
      await sl<FeedRepository>().recordShortView(
        shortId: widget.short.id,
        sessionId: _session,
        watched: watched,
        completed: completed,
        skippedEarly: watched.inMilliseconds < 1500,
      );
    } catch (_) {
      // Same as above.
    }
  }

  void _doubleTapLike(Offset position) {
    _heartAt = position;
    _heart.forward(from: 0);
    if (!widget.short.likedByMe) widget.onLike();
  }

  @override
  Widget build(BuildContext context) {
    final short = widget.short;
    return GestureDetector(
      onTap: () async {
        final controller = _controller;
        if (controller == null) return;
        if (controller.value.isPlaying) {
          await controller.pause();
          if (mounted) setState(() => _paused = true);
        } else {
          await controller.play();
          if (mounted) setState(() => _paused = false);
        }
      },
      onDoubleTapDown: (details) => _doubleTapLike(details.localPosition),
      onDoubleTap: () {},
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (_ready && _controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.size.width,
                height: _controller!.value.size.height,
                child: VideoPlayer(_controller!),
              ),
            )
          else
            const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator(color: Colors.white38)),
            ),
          // A soft gradient under the text so white type survives a bright frame.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.transparent, Color(0xB3000000)],
              ),
            ),
          ),
          if (_paused)
            const Center(
              child: Icon(Icons.play_arrow_rounded, size: 74, color: Colors.white70),
            ),
          Positioned(
            right: 10,
            bottom: 118,
            child: _ActionRail(
              short: short,
              tags: widget.tags,
              onLike: widget.onLike,
              onComment: widget.onComment,
              onSave: widget.onSave,
              onShare: widget.onShare,
              onProfile: widget.onProfile,
            ),
          ),
          Positioned(
            left: 14,
            right: 84,
            bottom: 28,
            child: _ReelInfo(
              short: short,
              tags: widget.tags,
              onFollow: widget.onFollow,
              onProfile: widget.onProfile,
              onSound: short.soundId == null ? null : () => context.push('/sound/${short.soundId}'),
            ),
          ),
          if (_heartAt != null)
            // Positioned is a direct child of the Stack; the animation lives
            // inside it, which is the only arrangement Flutter allows.
            Positioned(
              left: _heartAt!.dx - 46,
              top: _heartAt!.dy - 46,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _heart,
                  builder: (context, _) {
                    final t = _heart.value;
                    if (t == 0 || t == 1) return const SizedBox(width: 92, height: 92);
                    return Opacity(
                      opacity: (1 - t).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.7 + t * 0.9,
                        child: const Icon(Icons.favorite_rounded, color: Color(0xFFFF2E63), size: 92),
                      ),
                    );
                  },
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 2.5,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          Positioned(
            top: 92,
            left: 14,
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: _muted ? 'Unmute' : 'Mute',
                  onPressed: () async {
                    final controller = _controller;
                    if (controller == null) return;
                    await controller.setVolume(_muted ? 1 : 0);
                    if (mounted) setState(() => _muted = !_muted);
                  },
                  icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.short,
    required this.tags,
    required this.onLike,
    required this.onComment,
    required this.onSave,
    required this.onShare,
    required this.onProfile,
  });

  final ShortCard short;
  final List<TagSummary> tags;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RailAction(
          icon: short.likedByMe ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: short.likedByMe ? Brand.accent : Colors.white,
          label: compactCount(short.likeCount),
          onTap: onLike,
        ),
        _RailAction(
          icon: Icons.mode_comment_outlined,
          label: compactCount(short.commentCount),
          onTap: onComment,
        ),
        _RailAction(
          icon: short.savedByMe ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          color: short.savedByMe ? Brand.gold : Colors.white,
          label: compactCount(short.saveCount),
          onTap: onSave,
        ),
        _RailAction(icon: Icons.reply_rounded, label: compactCount(short.shareCount), onTap: onShare),
        GestureDetector(
          onTap: onProfile,
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: short.followedByMe ? Colors.white54 : Brand.accent,
                width: 2,
              ),
            ),
            child: PersonAvatar(
              name: short.authorName ?? 'Someone',
              path: short.authorAvatarPath,
              size: 40,
            ),
          ),
        ),
      ],
    );
  }
}

class _RailAction extends StatelessWidget {
  const _RailAction({required this.icon, required this.label, required this.onTap, this.color = Colors.white});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Column(
          children: <Widget>[
            Icon(icon, color: color, size: 31),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReelInfo extends StatelessWidget {
  const _ReelInfo({
    required this.short,
    required this.tags,
    required this.onFollow,
    required this.onProfile,
    this.onSound,
  });

  final ShortCard short;
  final List<TagSummary> tags;
  final VoidCallback onFollow;
  final VoidCallback onProfile;
  final VoidCallback? onSound;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: GestureDetector(
                onTap: onProfile,
                child: NameLine(
                  name: short.authorName ?? 'Someone',
                  handle: handleOf(short.authorUsername, short.authorDiscriminator),
                  tags: tags,
                  verified: short.authorVerified,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (!short.followedByMe)
              GestureDetector(
                onTap: onFollow,
                child: const Text(
                  'Follow',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13.5),
                ),
              ),
          ],
        ),
        if (short.caption != null && short.caption!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            short.caption!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.3),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Icon(Icons.music_note_rounded, color: Colors.white, size: 15),
            const SizedBox(width: 5),
            Flexible(
              child: GestureDetector(
                onTap: onSound,
                child: Text(
                  short.soundTitle == null
                      ? 'Original sound · ${short.authorName ?? ''}'
                      : '${short.soundTitle} · ${short.soundArtist ?? short.authorName ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                ),
              ),
            ),
            if (short.kind != 'original') ...<Widget>[
              const SizedBox(width: 8),
              BadgePill(label: short.kind.toUpperCase(), color: Brand.gold, icon: Icons.content_cut_rounded),
            ],
          ],
        ),
      ],
    );
  }
}
