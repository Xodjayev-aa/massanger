import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/discord_markdown.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../core/url_strategy.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../../data/shorts_repository.dart';
import '../auth/auth_bloc.dart';
import '../chats/chats_bloc.dart';
import '../chats/widgets.dart';

/// Video player screen supporting both direct [video] instances and `/video/:id`
/// route navigation via [videoId].
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    this.video,
    this.videoId,
  });

  final ShortVideo? video;
  final String? videoId;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  final ShortsRepository _shorts = sl<ShortsRepository>();
  ShortVideo? _video;
  VideoPlayerController? _controller;
  bool _loadingVideo = false;
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _liked = false;
  int _likes = 0;
  double _speed = 1.0;
  bool _controlsVisible = true;
  bool _descriptionExpanded = false;
  bool _downloading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final initial = widget.video;
    if (initial != null) {
      _applyVideo(initial);
      await _initPlayer(initial);
      return;
    }

    final targetId = widget.videoId?.trim() ?? '';
    if (targetId.isEmpty) {
      setState(() => _error = const AppException('not_found', 'Video not found.'));
      return;
    }

    setState(() {
      _loadingVideo = true;
      _error = null;
    });
    try {
      final loaded = await _shorts.getById(targetId);
      if (!mounted) return;
      if (loaded == null) {
        setState(() {
          _loadingVideo = false;
          _error = const AppException('not_found', 'Video not found.');
        });
        return;
      }
      _applyVideo(loaded);
      setState(() => _loadingVideo = false);
      await _initPlayer(loaded);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingVideo = false;
        _error = e;
      });
    }
  }

  void _applyVideo(ShortVideo video) {
    _video = video;
    _liked = video.likedByMe;
    _likes = video.likeCount;
    unawaited(_shorts.recordView(video.id));
  }

  Future<void> _initPlayer(ShortVideo video) async {
    VideoPlayerController? fresh;
    try {
      final url = await _shorts.watchUrl(video);
      fresh = VideoPlayerController.networkUrl(Uri.parse(url));
      await fresh.initialize();
      if (!mounted) return;
      fresh.addListener(_onPlayerTick);
      final old = _controller;
      _controller = fresh;
      fresh = null;
      await old?.dispose();
      setState(() {
        _isPlaying = true;
        _error = null;
      });
      await _controller?.play();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      try {
        await fresh?.dispose();
      } catch (_) {}
    }
  }

  void _onPlayerTick() {
    final c = _controller;
    if (!mounted || c == null) return;
    final playing = c.value.isPlaying;
    if (playing != _isPlaying) {
      setState(() => _isPlaying = playing);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    final c = _controller;
    if (c != null) {
      c.removeListener(_onPlayerTick);
      unawaited(c.dispose());
    }
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      unawaited(c.pause());
      setState(() => _isPlaying = false);
    } else {
      unawaited(c.play());
      setState(() => _isPlaying = true);
    }
  }

  Future<void> _toggleLike() async {
    final video = _video;
    if (video == null) return;
    final next = !_liked;
    setState(() {
      _liked = next;
      _likes += next ? 1 : -1;
    });
    try {
      if (next) {
        await _shorts.like(video.id);
      } else {
        await _shorts.unlike(video.id);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = !next;
          _likes += !next ? 1 : -1;
        });
      }
    }
  }

  void _cycleSpeed() {
    const speeds = <double>[0.5, 1.0, 1.25, 1.5, 2.0];
    final nextIndex = (speeds.indexOf(_speed) + 1) % speeds.length;
    final nextSpeed = speeds[nextIndex];
    setState(() => _speed = nextSpeed);
    unawaited(_controller?.setPlaybackSpeed(nextSpeed) ?? Future<void>.value());
  }

  Future<void> _downloadVideo() async {
    final video = _video;
    if (video == null || _downloading) return;
    setState(() => _downloading = true);
    try {
      final url = await _shorts.downloadUrl(video);
      if (!mounted) return;
      final opened = openBrowserDownloadUrl(url);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? 'Download started in your browser.'
                : 'Direct download is only supported in the web browser.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppException.wrap(e).message)),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _shareVideo() async {
    final video = _video;
    if (video == null) return;
    final link = DiscordMarkdown.shareVideoUrl(video.id);
    final label = video.title ?? video.caption ?? 'Video';
    final chats = context.read<ChatsBloc>().state.chats;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Share Video',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('Copy video link'),
              subtitle: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Video link copied to clipboard.')),
                );
              },
            ),
            const Divider(height: 1),
            if (chats.isEmpty)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline_rounded),
                title: const Text('Start a chat to share'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push(Routes.newChat());
                },
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chats.length,
                  itemBuilder: (itemContext, index) {
                    final chat = chats[index];
                    return ListTile(
                      leading: PersonAvatar(
                        name: chat.displayName,
                        path: chat.avatar ?? chat.peerAvatarPath,
                        size: 36,
                      ),
                      title: Text(
                        chat.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('Send video link in chat'),
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await _sendVideoToChat(chat, '$label\n$link');
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendVideoToChat(ChatSummary chat, String body) async {
    final uid = context.read<AuthBloc>().state.userId;
    if (uid == null || uid.isEmpty) return;
    try {
      await sl<ChatRepository>().send(
        chatId: chat.chatId,
        kind: MessageKind.text,
        clientMessageId: const Uuid().v4(),
        currentUserId: uid,
        body: body,
      );
      if (!mounted) return;
      context.read<ChatsBloc>().add(const ChatsRefreshRequested());
      context.push(Routes.chat(chat.chatId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppException.wrap(e).message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final video = _video;
    final c = _controller;

    if (_loadingVideo) {
      return Scaffold(
        appBar: AppBar(title: const Text('Video')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (video == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Video')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _error != null ? AppException.wrap(_error!).message : 'Video not found.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: _bootstrap,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(video.title ?? video.caption ?? 'Video', maxLines: 1),
        actions: <Widget>[
          TextButton(
            onPressed: _cycleSpeed,
            child: Text('${_speed}x', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: Icon(_isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
            onPressed: () {
              final next = !_isMuted;
              setState(() => _isMuted = next);
              unawaited(c?.setVolume(next ? 0 : 1) ?? Future<void>.value());
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // 16:9 Video Canvas
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Container(
                    color: Colors.black,
                    child: c != null && c.value.isInitialized
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: c.value.aspectRatio <= 0 ? 16 / 9 : c.value.aspectRatio,
                              child: VideoPlayer(c),
                            ),
                          )
                        : Center(
                            child: _error != null
                                ? Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      AppException.wrap(_error!).message,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white70),
                                    ),
                                  )
                                : const CircularProgressIndicator(),
                          ),
                  ),

                  // Overlay Controls
                  GestureDetector(
                    onTap: () => setState(() => _controlsVisible = !_controlsVisible),
                    behavior: HitTestBehavior.translucent,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        color: Colors.black38,
                        child: Center(
                          child: IconButton(
                            iconSize: 54,
                            icon: Icon(
                              _isPlaying
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_filled_rounded,
                              color: Colors.white,
                            ),
                            onPressed: _togglePlay,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Scrubber Bar
                  if (c != null && c.value.isInitialized)
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: VideoProgressIndicator(
                        c,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Color(0xFFFF0000),
                          bufferedColor: Colors.white30,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Video Details and Actions Scroll View
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                children: <Widget>[
                  // Title
                  Text(
                    video.title ?? video.caption ?? 'Untitled Video',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${video.viewCount} views • ${ChatFormatting.dayLabel(video.createdAt)}',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 14),

                  // Creator Row
                  Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          (video.authorName ?? 'U').substring(0, 1).toUpperCase(),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    video.authorName ?? '@creator',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ),
                                if (video.authorRoleBadge != null) ...<Widget>[
                                  const SizedBox(width: 6),
                                  DiscordRoleBadge(
                                    badge: video.authorRoleBadge!,
                                    colorHex: video.authorRoleColor,
                                    compact: true,
                                  ),
                                ],
                              ],
                            ),
                            if (video.authorUsername != null)
                              Text(
                                '@${video.authorUsername}',
                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Action Buttons: Like, Share, Download
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: _toggleLike,
                          icon: Icon(
                            _liked ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                            size: 18,
                            color: _liked ? scheme.primary : null,
                          ),
                          label: Text('$_likes'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _shareVideo,
                          icon: const Icon(Icons.share_rounded, size: 18),
                          label: const Text('Share'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _downloading ? null : _downloadVideo,
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: Text(_downloading ? 'Preparing…' : 'Download'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Expandable Description Box (with Discord markdown & #tags)
                  InkWell(
                    onTap: () => setState(() => _descriptionExpanded = !_descriptionExpanded),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withAlpha(100),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'Description',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const SizedBox(height: 6),
                          SelectableText.rich(
                            TextSpan(
                              children: DiscordMarkdown.parse(
                                video.description ?? video.caption ?? 'No description provided.',
                                context: context,
                              ),
                            ),
                            maxLines: _descriptionExpanded ? null : 3,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _descriptionExpanded ? 'Show less' : '...more',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: scheme.primary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
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
}
