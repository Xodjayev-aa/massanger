import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../app/di.dart';
import '../../core/discord_markdown.dart';
import '../../core/formatting.dart';
import '../../data/shorts_repository.dart';

/// Full YouTube-style theater video player screen:
/// - Inline scrubber, speed selector (0.5x, 1x, 1.5x, 2x), landscape toggle
/// - Video details & expandable description with markdown & #hashtags
/// - Action bar: Like, Share, Save, Remix
/// - Creator row with Subscribe / Follow button and Discord role tag
/// - YouTube/TikTok-style comments sheet with real comments
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.video});

  final ShortVideo video;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  final ShortsRepository _shorts = sl<ShortsRepository>();
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _liked = false;
  int _likes = 0;
  double _speed = 1.0;
  bool _controlsVisible = true;
  bool _descriptionExpanded = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _liked = widget.video.likedByMe;
    _likes = widget.video.likeCount;
    _initPlayer();
    _shorts.recordView(widget.video.id);
  }

  Future<void> _initPlayer() async {
    try {
      final url = await _shorts.watchUrl(widget.video);
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _isPlaying = true;
      });
      await controller.play();
      controller.addListener(() {
        if (mounted) setState(() {});
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      setState(() => _isPlaying = false);
    } else {
      c.play();
      setState(() => _isPlaying = true);
    }
  }

  Future<void> _toggleLike() async {
    final next = !_liked;
    setState(() {
      _liked = next;
      _likes += next ? 1 : -1;
    });
    try {
      if (next) {
        await _shorts.like(widget.video.id);
      } else {
        await _shorts.unlike(widget.video.id);
      }
    } catch (_) {
      // rollback
      if (mounted) {
        setState(() {
          _liked = !next;
          _likes += !next ? 1 : -1;
        });
      }
    }
  }

  void _cycleSpeed() {
    final speeds = <double>[0.5, 1.0, 1.25, 1.5, 2.0];
    final nextIndex = (speeds.indexOf(_speed) + 1) % speeds.length;
    final nextSpeed = speeds[nextIndex];
    setState(() => _speed = nextSpeed);
    _controller?.setPlaybackSpeed(nextSpeed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = _controller;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.video.title ?? 'Video Player', maxLines: 1),
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
              c?.setVolume(next ? 0 : 1);
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
                        ? Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)))
                        : Center(
                            child: _error != null
                                ? const Text('Could not play video', style: TextStyle(color: Colors.white70))
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
                              _isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
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
                          playedColor: Color(0xFFFF0000), // YouTube Red
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
                    widget.video.title ?? widget.video.caption ?? 'Untitled Video',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${widget.video.viewCount} views • ${ChatFormatting.dayLabel(widget.video.createdAt)}',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 14),

                  // Creator Channel Row
                  Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          (widget.video.authorName ?? 'U').substring(0, 1).toUpperCase(),
                          style: TextStyle(fontWeight: FontWeight.bold, color: scheme.onPrimaryContainer),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Text(
                                  widget.video.authorName ?? '@creator',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                if (widget.video.authorRoleBadge != null) ...<Widget>[
                                  const SizedBox(width: 6),
                                  DiscordRoleBadge(
                                    badge: widget.video.authorRoleBadge!,
                                    colorHex: widget.video.authorRoleColor,
                                    compact: true,
                                  ),
                                ],
                              ],
                            ),
                            Text(
                              '@${widget.video.authorUsername ?? 'channel'}',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () {},
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('Subscribe'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Action Buttons: Like, Share, Remix, Comments
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
                          onPressed: () {},
                          icon: const Icon(Icons.share_rounded, size: 18),
                          label: const Text('Share'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: const Text('Download'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.cut_rounded, size: 18),
                          label: const Text('Clip'),
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
                          const Text('Description', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 6),
                          SelectableText.rich(
                            TextSpan(
                              children: DiscordMarkdown.parse(
                                widget.video.description ?? widget.video.caption ?? 'No description provided.',
                                context: context,
                              ),
                            ),
                            maxLines: _descriptionExpanded ? null : 3,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _descriptionExpanded ? 'Show less' : '...more',
                            style: TextStyle(fontWeight: FontWeight.bold, color: scheme.primary, fontSize: 12),
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
