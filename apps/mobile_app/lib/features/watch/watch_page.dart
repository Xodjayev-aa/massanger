import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../core/errors.dart';
import '../../data/economy_repository.dart';
import '../../data/feed_repository.dart';
import '../../data/media_cache.dart';
import '../../data/voice_over.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';
import '../feed/video_tile.dart';
import 'comments.dart';
import 'player.dart';

/// The long-form watch page: the player, the numbers, the actions a viewer
/// expects (like, dislike, save, share, tip) and the comment tree beneath it.
///
/// One RPC — `video_detail` — brings the row, the author, the sound and an
/// up-next rail, so the page has a single loading state instead of four.
class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.videoId});

  final String videoId;

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  Map<String, dynamic> _video = <String, dynamic>{};
  List<Map<String, dynamic>> _upNext = <Map<String, dynamic>>[];
  Map<String, dynamic>? _sound;
  List<TagSummary> _tags = const <TagSummary>[];
  String? _playbackUrl;
  bool _loading = true;
  bool _descriptionOpen = false;
  bool _saved = false;
  Object? _error;
  String? _session;

  @override
  void initState() {
    super.initState();
    _session = 'watch-${DateTime.now().microsecondsSinceEpoch}';
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await sl<FeedRepository>().video(widget.videoId);
      final video = detail['video'] is Map ? Map<String, dynamic>.from(detail['video'] as Map) : <String, dynamic>{};
      final url = await sl<MediaCache>().url(video['object_key'] as String?);
      final authorId = '${video['author_id']}';
      List<TagSummary> tags = const <TagSummary>[];
      try {
        tags = (await sl<SocialRepository>().tagsFor(<String>[authorId]))[authorId] ?? const <TagSummary>[];
      } catch (_) {
        // Tags are decoration.
      }
      if (!mounted) return;
      setState(() {
        _video = video;
        _tags = tags;
        _playbackUrl = url;
        _upNext = (detail['up_next'] is List)
            ? (detail['up_next'] as List).map((row) => Map<String, dynamic>.from(row as Map)).toList(growable: false)
            : <Map<String, dynamic>>[];
        _sound = detail['sound'] is Map ? Map<String, dynamic>.from(detail['sound'] as Map) : null;
        _loading = false;
      });
      unawaited(_recordView(Duration.zero, Duration.zero));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _recordView(Duration position, Duration watched) async {
    final session = _session;
    if (session == null) return;
    try {
      await sl<FeedRepository>().recordVideoView(
        videoId: widget.videoId,
        sessionId: session,
        position: position,
        watched: watched,
      );
    } catch (_) {
      // Telemetry only.
    }
  }

  Future<void> _rate(String verdict) async {
    final current = '${_video['my_verdict'] ?? ''}';
    final next = current == verdict ? 'none' : verdict;
    try {
      final settled = await sl<FeedRepository>().rateVideo(widget.videoId, next);
      if (!mounted) return;
      setState(() {
        _video['my_verdict'] = settled == 'none' ? null : settled;
        final likes = (_video['like_count'] as num?)?.toInt() ?? 0;
        final dislikes = (_video['dislike_count'] as num?)?.toInt() ?? 0;
        if (current == 'like') _video['like_count'] = (likes - 1).clamp(0, 1 << 30);
        if (current == 'dislike') _video['dislike_count'] = (dislikes - 1).clamp(0, 1 << 30);
        if (settled == 'like') _video['like_count'] = ((_video['like_count'] as num?)?.toInt() ?? 0) + 1;
        if (settled == 'dislike') _video['dislike_count'] = ((_video['dislike_count'] as num?)?.toInt() ?? 0) + 1;
      });
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _toggleWatchLater() async {
    try {
      final on = await sl<FeedRepository>().toggleWatchLater(widget.videoId);
      if (!mounted) return;
      setState(() => _saved = on);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(on ? 'Saved to Watch later' : 'Removed from Watch later')),
      );
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _follow() async {
    final authorId = '${_video['author_id']}';
    final following = _video['followed_by_me'] == true;
    try {
      if (following) {
        await sl<SocialRepository>().unfollow(authorId);
      } else {
        final state = await sl<SocialRepository>().follow(userId: authorId);
        if (state == 'pending' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Request sent — this account approves follows first.')),
          );
        }
      }
      if (mounted) setState(() => _video['followed_by_me'] = !following);
    } catch (error) {
      _toast(error);
    }
  }

  Future<void> _tip() async {
    final amount = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _TipSheet(name: '${_video['author_name'] ?? 'this creator'}'),
    );
    if (amount == null) return;
    try {
      await sl<EconomyRepository>().sendGift(
        recipientId: '${_video['author_id']}',
        stars: amount,
        kind: 'video',
        videoId: widget.videoId,
        note: 'Tip for “${_video['title']}”',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent $amount Stars')),
      );
    } catch (error) {
      _toast(error);
    }
  }

  void _toast(Object error) {
    if (!mounted) return;
    final message = error is AppException ? error.message : 'Something went wrong.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          title: 'That video is not available',
          message: _error is AppException ? (_error! as AppException).message : 'It may have been removed.',
          icon: Icons.videocam_off_outlined,
          action: FilledButton(onPressed: () => context.go('/home'), child: const Text('Back to home')),
        ),
      );
    }

    final title = '${_video['title'] ?? ''}';
    final description = '${_video['description'] ?? ''}';
    final tags = (_video['tags'] is List) ? (_video['tags'] as List).map((t) => '$t').toList(growable: false) : const <String>[];
    final chapters = (_video['chapters'] is List) ? (_video['chapters'] as List) : const <dynamic>[];
    final verdict = '${_video['my_verdict'] ?? ''}';

    return Scaffold(
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            pinned: true,
            title: const BrandLockup(size: 24),
            actions: <Widget>[
              IconButton(
                tooltip: 'Share',
                icon: const Icon(Icons.ios_share_rounded),
                onPressed: () async {
                  await sl<FeedRepository>().shareVideo(widget.videoId).catchError((Object _) {});
                  if (!mounted) return;
                  await showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    builder: (sheetContext) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          ListTile(
                            leading: const Icon(Icons.send_rounded),
                            title: const Text('Send to a chat'),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              context.push('/chats');
                            },
                          ),
                          ListTile(
                            leading: const Icon(Icons.link_rounded),
                            title: const Text('Copy link'),
                            subtitle: Text('messengerx.app/watch/${widget.videoId}'),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(content: Text('Link copied')));
                            },
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _playbackUrl == null
                ? const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ColoredBox(color: Colors.black, child: Center(child: CircularProgressIndicator(color: Colors.white54))),
                  )
                : VideoSurface(
                    url: _playbackUrl!,
                    initialPosition: Duration(milliseconds: (() {
                      final watch = _video['watch'];
                      if (watch is Map) return (watch['position_ms'] as num?)?.toInt() ?? 0;
                      return 0;
                    })()),
                    onPosition: (position, watched) => unawaited(_recordView(position, watched)),
                  ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.25)),
                  const SizedBox(height: 6),
                  Text(
                    '${compactCount((_video['view_count'] as num?)?.toInt() ?? 0)} views · '
                    '${relativeTime(DateTime.tryParse('${_video['published_at']}')?.toUtc() ?? DateTime.now().toUtc())}'
                    '${_video['category_label'] == null ? '' : ' · ${_video['category_label']}'}',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        _Pill(
                          icon: verdict == 'like' ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
                          label: compactCount((_video['like_count'] as num?)?.toInt() ?? 0),
                          active: verdict == 'like',
                          onTap: () => _rate('like'),
                        ),
                        _Pill(
                          icon: verdict == 'dislike' ? Icons.thumb_down_rounded : Icons.thumb_down_outlined,
                          label: compactCount((_video['dislike_count'] as num?)?.toInt() ?? 0),
                          active: verdict == 'dislike',
                          onTap: () => _rate('dislike'),
                        ),
                        _Pill(
                          icon: Icons.forum_outlined,
                          label: compactCount((_video['comment_count'] as num?)?.toInt() ?? 0),
                          onTap: () {},
                        ),
                        _Pill(
                          icon: _saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                          label: 'Save',
                          active: _saved,
                          onTap: _toggleWatchLater,
                        ),
                        _Pill(
                          icon: Icons.card_giftcard_rounded,
                          label: 'Tip',
                          onTap: _tip,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      GestureDetector(
                        onTap: () => context.push('/u/${_video['author_id']}'),
                        child: PersonAvatar(
                          name: '${_video['author_name'] ?? 'Someone'}',
                          path: _video['author_avatar'] as String?,
                          size: 42,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => context.push('/u/${_video['author_id']}'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              NameLine(
                                name: '${_video['author_name'] ?? 'Someone'}',
                                handle: handleOf(
                                  _video['author_username'] as String?,
                                  (_video['author_discriminator'] as num?)?.toInt(),
                                ),
                                tags: _tags,
                                verified: _video['author_verified'] == true,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${compactCount((_video['author_followers'] as num?)?.toInt() ?? 0)} followers',
                                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                      FollowButton(
                        following: _video['followed_by_me'] == true,
                        onPressed: _follow,
                      ),
                    ],
                  ),
                  if (description.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    GestureDetector(
                      onTap: () => setState(() => _descriptionOpen = !_descriptionOpen),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              description,
                              maxLines: _descriptionOpen ? null : 3,
                              overflow: _descriptionOpen ? null : TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5, height: 1.45),
                            ),
                            if (tags.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: <Widget>[
                                  for (final tag in tags)
                                    Text('#$tag', style: TextStyle(fontSize: 12.5, color: scheme.primary)),
                                ],
                              ),
                            ],
                            if (chapters.isNotEmpty) ...<Widget>[
                              const Divider(height: 22),
                              Text('Chapters', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 6),
                              for (final chapter in chapters.take(12))
                                if (chapter is Map)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Row(
                                      children: <Widget>[
                                        const Icon(Icons.playlist_play_rounded, size: 16),
                                        const SizedBox(width: 6),
                                        Text(
                                          _chapterStamp(chapter['t'] ?? chapter['time'] ?? chapter['start']),
                                          style: TextStyle(fontSize: 12.5, color: scheme.primary, fontWeight: FontWeight.w700),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '${chapter['title'] ?? chapter['label'] ?? ''}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 12.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                            ],
                            if (_sound != null && _sound!['id'] != null) ...<Widget>[
                              const Divider(height: 22),
                              GestureDetector(
                                onTap: () => context.push('/sound/${_sound!['id']}'),
                                child: Row(
                                  children: <Widget>[
                                    const Icon(Icons.music_note_rounded, size: 16),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${_sound!['title']}'
                                        '${_sound!['voice_name'] == null ? '' : ' · AI voice ${_sound!['voice_name']}'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right_rounded, size: 18),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_upNext.isNotEmpty) ...<Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
                child: Text('Up next', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: scheme.onSurface)),
              ),
            ),
            SliverList.builder(
              itemCount: _upNext.length,
              itemBuilder: (context, index) {
                final row = _upNext[index];
                final video = VideoCard.fromMap(row);
                return VideoRowTile(video: video, media: sl<MediaCache>());
              },
            ),
          ],
          SliverToBoxAdapter(
            child: SizedBox(
              height: 520,
              child: CommentsPanel(
                videoId: widget.videoId,
                totalCount: (_video['comment_count'] as num?)?.toInt() ?? 0,
                creatorId: _video['author_id'] as String?,
                shrinkWrap: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _chapterStamp(Object? raw) {
    if (raw is num) {
      final seconds = raw.toInt();
      return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    }
    if (raw is String && raw.isNotEmpty) return raw;
    return '0:00';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.onTap, this.active = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active
            ? (isDark ? Colors.white : Colors.black87)
            : (isDark ? const Color(0xFF24262B) : const Color(0xFFF0F1F4)),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: <Widget>[
                Icon(
                  icon,
                  size: 18,
                  color: active ? (isDark ? Colors.black : Colors.white) : scheme.onSurface,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active ? (isDark ? Colors.black : Colors.white) : scheme.onSurface,
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

class _TipSheet extends StatefulWidget {
  const _TipSheet({required this.name});

  final String name;

  @override
  State<_TipSheet> createState() => _TipSheetState();
}

class _TipSheetState extends State<_TipSheet> {
  int _amount = 25;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Tip ${widget.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Stars go straight to the creator. 100% of a gift is theirs.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final amount in <int>[10, 25, 50, 100, 250])
                  ChoiceChip(
                    label: Text('$amount ⭐'),
                    selected: _amount == amount,
                    onSelected: (_) => setState(() => _amount = amount),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_amount),
              child: Text('Send $_amount Stars'),
            ),
          ],
        ),
      ),
    );
  }
}

/// `/watch/short/:id` — a single reel with its comment sheet. Opened from the
/// reels overlay, from a share link, and from a profile grid.
class ShortWatchPage extends StatefulWidget {
  const ShortWatchPage({super.key, required this.shortId});

  final String shortId;

  @override
  State<ShortWatchPage> createState() => _ShortWatchPageState();
}

class _ShortWatchPageState extends State<ShortWatchPage> {
  ShortCard? _short;
  String? _url;
  bool _loading = true;
  bool _missing = false;
  String? _session;

  @override
  void initState() {
    super.initState();
    _session = 'reel-${DateTime.now().microsecondsSinceEpoch}';
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final short = await sl<FeedRepository>().short(widget.shortId);
      final url = short == null ? null : await sl<MediaCache>().url(short.key);
      if (!mounted) return;
      setState(() {
        _short = short;
        _url = url;
        _missing = short == null;
        _loading = false;
      });
      if (short != null) {
        unawaited(sl<FeedRepository>().recordShortView(shortId: short.id, sessionId: _session!).catchError((Object _) {}));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _missing = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final short = _short;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Reel'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _missing || short == null || _url == null
              ? const EmptyState(
                  title: 'That reel is not available',
                  message: 'It may have been removed, or it is not meant for you.',
                  icon: Icons.movie_filter_outlined,
                )
              : Column(
                  children: <Widget>[
                    Expanded(
                      child: Center(
                        child: VideoSurface(
                          url: _url!,
                          loop: true,
                          onPosition: (position, watched) => unawaited(
                            sl<FeedRepository>()
                                .recordShortView(
                                  shortId: short.id,
                                  sessionId: _session!,
                                  watched: watched,
                                  completed: position >= short.duration - const Duration(milliseconds: 250),
                                )
                                .catchError((Object _) {}),
                          ),
                        ),
                      ),
                    ),
                    if (short.caption != null && short.caption!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Text(short.caption!, style: const TextStyle(color: Colors.white, fontSize: 14)),
                      ),
                    Expanded(
                      child: Theme(
                        data: Theme.of(context).copyWith(brightness: Brightness.light),
                        child: CommentsPanel(
                          shortId: widget.shortId,
                          totalCount: short.commentCount,
                          creatorId: short.authorId,
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// `/sound/:id` — every short using one sound, plus the AI voice-over details.
class SoundPage extends StatefulWidget {
  const SoundPage({super.key, required this.soundId});

  final String soundId;

  @override
  State<SoundPage> createState() => _SoundPageState();
}

class _SoundPageState extends State<SoundPage> {
  List<ShortCard> _shorts = const <ShortCard>[];
  SoundSummary? _sound;
  bool _loading = true;
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final sounds = await sl<FeedRepository>().sounds(limit: 100);
      final shorts = await sl<FeedRepository>().shorts(tab: 'sound', soundId: widget.soundId, limit: 40);
      SoundSummary? sound;
      for (final candidate in sounds) {
        if (candidate.id == widget.soundId) sound = candidate;
      }
      if (!mounted) return;
      setState(() {
        _sound = sound;
        _shorts = shorts;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Re-renders an AI voice-over on this device.
  ///
  /// This is the payoff of storing the script instead of the audio: nothing has
  /// to be downloaded, nothing has to be paid for, and the voice can be the one
  /// this phone happens to have. A recording-backed sound is played by the reels
  /// themselves, so there is no second player here.
  Future<void> _speak() async {
    final sound = _sound;
    final script = sound?.voiceScript;
    if (sound == null || script == null || script.isEmpty) return;
    final tts = sl<VoiceOverService>();
    if (_speaking) {
      await tts.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    setState(() => _speaking = true);
    try {
      await tts.select(VoiceOption(name: sound.voiceName ?? '', locale: sound.voiceLocale ?? ''));
      await tts.speak(script);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error is AppException ? error.message : 'This device cannot speak the voice-over.')),
        );
      }
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  @override
  void dispose() {
    unawaited(sl<VoiceOverService>().stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sound = _sound;
    return Scaffold(
      appBar: AppBar(title: Text(sound?.title ?? 'Sound')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: Brand.gradient),
                        child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 30),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(sound?.title ?? 'Original sound', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 2),
                            Text(
                              '${sound?.artist ?? 'Unknown artist'} · ${compactCount(sound?.useCount ?? _shorts.length)} reels',
                              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                            ),
                            if (sound?.isVoiceOver == true) ...<Widget>[
                              const SizedBox(height: 6),
                              BadgePill(
                                label: 'AI voice-over · ${sound!.voiceName ?? 'device voice'}',
                                icon: Icons.graphic_eq_rounded,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (sound?.voiceScript != null && sound!.voiceScript!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(sound.voiceScript!, style: const TextStyle(fontSize: 13, height: 1.4)),
                    ),
                  ),
                if (sound?.isVoiceOver == true && (sound?.voiceScript?.isNotEmpty ?? false))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Row(
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          onPressed: _speak,
                          icon: Icon(_speaking ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18),
                          label: Text(_speaking ? 'Stop' : 'Play voice-over here'),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            'Rendered by this device’s speech engine.',
                            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                for (final short in _shorts)
                  ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: const Icon(Icons.play_arrow_rounded),
                        ),
                      ),
                    ),
                    title: Text(short.caption ?? 'Reel', maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${compactCount(short.likeCount)} likes · ${relativeTime(short.createdAt)}'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push('/watch/short/${short.id}'),
                  ),
                if (_shorts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(28),
                    child: EmptyState(title: 'No reels use this sound yet', icon: Icons.music_off_rounded),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
