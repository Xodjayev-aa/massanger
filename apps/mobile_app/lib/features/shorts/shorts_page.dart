import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/shorts_repository.dart';
import '../../data/video_repository.dart';
import '../chats/widgets.dart';

/// The Shorts feed: full-screen, vertical, one clip per swipe, muted autoplay
/// with a tap to hear — the interaction the Phase-1 spec asks for, with no
/// second navigation stack around it.
///
/// Data comes from [ShortsRepository] (keyset pages over `shorts`), playback
/// from a presigned B2 GET minted by `video-ticket`, and likes are optimistic
/// locally with the server row as the tiebreaker.
class ShortsPage extends StatefulWidget {
  const ShortsPage({super.key});

  @override
  State<ShortsPage> createState() => _ShortsPageState();
}

class _ShortsPageState extends State<ShortsPage> {
  final ShortsRepository _shorts = sl<ShortsRepository>();
  final PageController _page = PageController();
  final List<ShortVideo> _items = <ShortVideo>[];

  int _index = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;

  /// null = still asking `video-ticket status`.
  bool? _configured;
  Object? _error;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _disposed = true;
    _page.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final configured = await sl<VideoRepository>().isConfigured();
    if (_disposed) return;
    setState(() {
      _configured = configured;
      _loading = false;
    });
    if (configured) await _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && _loadingMore) return;
    if (!reset) setState(() => _loadingMore = true);
    if (reset) setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final beforeId = reset || _items.isEmpty ? null : _items.last.id;
      final next = await _shorts.page(beforeId: beforeId);
      if (_disposed) return;
      setState(() {
        if (reset) {
          _items
            ..clear()
            ..addAll(next);
        } else {
          _items.addAll(next);
        }
        if (next.length < ShortsRepository.pageSize) _hasMore = false;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (error) {
      if (_disposed) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        // Pagination trouble on a populated feed is not worth blanking the
        // screen — the next swipe retries.
        if (_items.isEmpty) _error = error;
      });
      if (_items.isNotEmpty) _show(AppException.wrap(error).message);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    await _load(reset: false);
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    if (index >= _items.length - 3) _loadMore();
  }

  Future<void> _create() async {
    if (_configured == false) {
      _show('Video is not enabled on this deployment.');
      return;
    }
    try {
      final picked = await ImagePicker().pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(seconds: 60),
      );
      if (picked == null || !mounted) return;
      final caption = await showDialog<String>(
        context: context,
        builder: (dialogContext) => _ShortCaptionDialog(fileName: picked.name),
      );
      final created = await _shorts.publish(file: picked, caption: caption);
      if (_disposed) return;
      setState(() {
        _items.insert(0, created);
        _index = 0;
        _hasMore = true;
      });
      if (_page.hasClients) _page.jumpToPage(0);
    } on AppException catch (error) {
      _show(error.message);
    } catch (_) {
      _show('That video could not be published.');
    }
  }

  Future<void> _toggleLike(int index) async {
    if (index < 0 || index >= _items.length) return;
    final short = _items[index];
    final liked = !short.likedByMe;
    setState(() {
      _items[index] = short.copyWith(
        likedByMe: liked,
        likeCount: short.likeCount + (liked ? 1 : -1),
      );
    });
    try {
      if (liked) {
        await _shorts.like(short.id);
      } else {
        await _shorts.unlike(short.id);
      }
    } catch (error) {
      if (_disposed) return;
      setState(() => _items[index] = short); // roll the optimistic flip back
      _show(AppException.wrap(error).message);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: _body()),
            const _BackButton(),
          ],
        ),
      ),
      floatingActionButton: _configured == false
          ? null
          : FloatingActionButton(
              onPressed: _create,
              tooltip: 'Post a short',
              child: const Icon(Icons.add_rounded),
            ),
    );
  }

  Widget _body() {
    if (_configured == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_configured == false) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Video is not enabled on this deployment.\nThe operator can turn it on with B2 secrets.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return Center(
        child: InlineError(
          message: AppException.wrap(_error!).message,
          onRetry: () => _load(reset: true),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          'No shorts yet — be the first.',
          style: TextStyle(color: Colors.white70, fontSize: 16),
        ),
      );
    }
    return PageView.builder(
      controller: _page,
      scrollDirection: Axis.vertical,
      onPageChanged: _onPageChanged,
      itemCount: _items.length,
      itemBuilder: (context, index) => _ShortView(
        key: ValueKey<String>(_items[index].id),
        short: _items[index],
        active: index == _index,
        onToggleLike: () => _toggleLike(index),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 4,
      left: 4,
      child: IconButton(
        tooltip: 'Back',
        onPressed: () => context.canPop() ? context.pop() : context.go(Routes.chats),
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
      ),
    );
  }
}

/// One full-screen clip. Owns its controller: muted autoplay while active,
/// paused the moment the feed moves on, disposed with the page.
class _ShortView extends StatefulWidget {
  const _ShortView({
    super.key,
    required this.short,
    required this.active,
    required this.onToggleLike,
  });

  final ShortVideo short;
  final bool active;
  final VoidCallback onToggleLike;

  @override
  State<_ShortView> createState() => _ShortViewState();
}

class _ShortViewState extends State<_ShortView> {
  final ShortsRepository _shorts = sl<ShortsRepository>();
  VideoPlayerController? _controller;
  Object? _error;
  bool _muted = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(_ShortView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      if (_controller == null) {
        _start();
      } else {
        _resume();
      }
    } else if (!widget.active && oldWidget.active) {
      final controller = _controller;
      if (controller != null && controller.value.isPlaying) controller.pause();
    }
  }

  void _resume() {
    final controller = _controller;
    if (controller != null && !controller.value.isPlaying) controller.play();
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    _starting = true;
    // Same ownership discipline as the viewer: `fresh` lives until the
    // controller is handed to `_controller`, so failures and closed pages
    // dispose exactly once and never twice.
    VideoPlayerController? fresh;
    try {
      final url = await _shorts.watchUrl(widget.short);
      fresh = VideoPlayerController.networkUrl(Uri.parse(url));
      await fresh.initialize();
      if (!mounted) return;
      await fresh.setLooping(true);
      await fresh.setVolume(_muted ? 0 : 1);
      _controller = fresh;
      fresh = null;
      setState(() {});
      if (widget.active) await _controller?.play();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      try {
        await fresh?.dispose();
      } catch (_) {
        // Best-effort cleanup of a controller that never reached the State.
      }
      _starting = false;
    }
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null) return;
    final muted = !_muted;
    setState(() => _muted = muted);
    await controller.setVolume(muted ? 0 : 1);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _toggleMute,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ColoredBox(color: Colors.black),
          Center(
            child: _error != null
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.videocam_off_rounded, color: Colors.white54, size: 40),
                      SizedBox(height: 8),
                      Text('This video could not be played.', style: TextStyle(color: Colors.white70)),
                    ],
                  )
                : controller == null
                    ? const CircularProgressIndicator()
                    : AspectRatio(
                        aspectRatio: controller.value.aspectRatio <= 0 ? 9 / 16 : controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
          ),
          // Author + caption, bottom-left: the feed's only text furniture.
          Positioned(
            left: 16,
            right: 84,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.short.authorName ?? '@unknown',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    shadows: <Shadow>[Shadow(blurRadius: 8, color: Colors.black54)],
                  ),
                ),
                if (widget.short.authorUsername != null)
                  Text(
                    '@${widget.short.authorUsername}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                if ((widget.short.caption ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      widget.short.caption!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
          // Action rail, right side: sound, like.
          Positioned(
            right: 8,
            bottom: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: _muted ? 'Sound on' : 'Mute',
                  onPressed: _toggleMute,
                  icon: Icon(
                    _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    color: Colors.white,
                    shadows: const <Shadow>[Shadow(blurRadius: 8, color: Colors.black54)],
                  ),
                ),
                const SizedBox(height: 4),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: widget.short.likedByMe ? 'Unlike' : 'Like',
                      onPressed: widget.onToggleLike,
                      icon: Icon(
                        widget.short.likedByMe ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: widget.short.likedByMe ? scheme.error : Colors.white,
                        shadows: const <Shadow>[Shadow(blurRadius: 8, color: Colors.black54)],
                      ),
                    ),
                    Text(
                      '${widget.short.likeCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        shadows: <Shadow>[Shadow(blurRadius: 6, color: Colors.black54)],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortCaptionDialog extends StatefulWidget {
  const _ShortCaptionDialog({required this.fileName});

  final String fileName;

  @override
  State<_ShortCaptionDialog> createState() => _ShortCaptionDialogState();
}

class _ShortCaptionDialogState extends State<_ShortCaptionDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 500,
        maxLines: 3,
        decoration: const InputDecoration(hintText: 'Add a caption (optional)', counterText: ''),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Post without caption'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Post'),
        ),
      ],
    );
  }
}
