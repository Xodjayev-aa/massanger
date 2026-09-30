import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// The playback surface used by the watch page and the reels grid.
///
/// One place decides what "watching" means: when the controller is created, how
/// often the position is reported (so `record_video_view` gets a resume point
/// without a write per frame), and what a failure looks like. The URL is always
/// a presigned B2 link minted by the repository — the widget never talks to S3
/// itself.
class VideoSurface extends StatefulWidget {
  const VideoSurface({
    super.key,
    required this.url,
    this.autoPlay = true,
    this.loop = false,
    this.initialPosition = Duration.zero,
    this.aspectRatio,
    this.onPosition,
    this.onCompleted,
    this.onToggleFullscreen,
    this.fullscreen = false,
    this.controlsAlwaysVisible = false,
  });

  final String url;
  final bool autoPlay;
  final bool loop;

  /// Resume point: the player seeks here once it is ready.
  final Duration initialPosition;

  /// When null the surface takes the video's own aspect ratio.
  final double? aspectRatio;

  /// Called at most every few seconds with the current position, and once with
  /// the final position when the video ends.
  final void Function(Duration position, Duration watched)? onPosition;
  final VoidCallback? onCompleted;
  final VoidCallback? onToggleFullscreen;
  final bool fullscreen;
  final bool controlsAlwaysVisible;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _playing = false;
  bool _dragging = false;
  bool _controlsVisible = true;
  double _dragValue = 0;
  Duration _watched = Duration.zero;
  Duration _lastReported = Duration.zero;
  Duration _lastPosition = Duration.zero;
  int _lastSecond = -1;
  bool _endedReported = false;
  Timer? _hideControls;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void didUpdateWidget(VideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      unawaited(_disposeController());
      unawaited(_open());
    }
  }

  @override
  void dispose() {
    _hideControls?.cancel();
    unawaited(_disposeController());
    super.dispose();
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onTick);
      await controller.dispose();
    }
  }

  Future<void> _open() async {
    setState(() {
      _error = null;
      _ready = false;
    });
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(widget.loop);
      if (widget.initialPosition > Duration.zero) {
        await controller.seekTo(widget.initialPosition);
      }
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _ready = true;
        _playing = controller.value.isPlaying;
      });
      if (widget.autoPlay) await controller.play();
      if (mounted) setState(() => _playing = controller.value.isPlaying);
      _scheduleHide();
    } catch (error) {
      await controller.dispose();
      if (mounted) setState(() => _error = error);
    }
  }

  /// Reports the position every ~5 s of playback, plus each time it ends, which
  /// is what `watch_progress` merges with `greatest(position_ms)`.
  ///
  /// Watched time comes from position deltas rather than from a tick counter:
  /// the listener fires on buffering and on seek too, and a stalled frame is not
  /// something anybody watched.
  void _onTick() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;

    if (value.isPlaying) {
      final position = value.position;
      final delta = position - _lastPosition;
      if (delta > Duration.zero && delta < const Duration(seconds: 5)) _watched += delta;
      _lastPosition = position;
      if ((position - _lastReported).abs() > const Duration(seconds: 5)) {
        _lastReported = position;
        widget.onPosition?.call(position, _watched);
      }
    }

    final ended = value.duration > Duration.zero && value.position >= value.duration;
    if (ended && !_endedReported) {
      _endedReported = true;
      widget.onPosition?.call(value.position, _watched);
      widget.onCompleted?.call();
    }

    // Repainting the chrome is only worth it when the second or the play state
    // actually changed — the listener runs far more often than that.
    final second = value.position.inSeconds;
    if (value.isPlaying != _playing || second != _lastSecond) {
      _lastSecond = second;
      setState(() => _playing = value.isPlaying);
    }
  }

  void _scheduleHide() {
    _hideControls?.cancel();
    if (widget.controlsAlwaysVisible) return;
    _hideControls = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _reveal() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      _hideControls?.cancel();
    } else {
      await controller.play();
      _scheduleHide();
    }
    if (mounted) setState(() => _playing = controller.value.isPlaying);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final aspect = widget.aspectRatio ??
        (_ready && controller != null && controller.value.aspectRatio > 0
            ? controller.value.aspectRatio
            : 16 / 9);

    return AspectRatio(
      aspectRatio: aspect <= 0 ? 16 / 9 : aspect,
      child: ColoredBox(
        color: Colors.black,
        child: _error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.error_outline_rounded, color: Colors.white70, size: 34),
                    const SizedBox(height: 8),
                    const Text('This video could not be played', style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => unawaited(_open()),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            : !_ready || controller == null
                ? const Center(child: CircularProgressIndicator(color: Colors.white54))
                : GestureDetector(
                    onTap: () {
                      _reveal();
                      unawaited(_togglePlay());
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        Center(
                          child: AspectRatio(
                            aspectRatio: controller.value.aspectRatio <= 0 ? 16 / 9 : controller.value.aspectRatio,
                            child: VideoPlayer(controller),
                          ),
                        ),
                        if (!_playing)
                          const Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                              child: Padding(
                                padding: EdgeInsets.all(10),
                                child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 44),
                              ),
                            ),
                          ),
                        if (_controlsVisible || widget.controlsAlwaysVisible)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _Controls(
                              controller: controller,
                              dragging: _dragging,
                              dragValue: _dragValue,
                              fullscreen: widget.fullscreen,
                              onToggleFullscreen: widget.onToggleFullscreen,
                              onStartDrag: () => setState(() {
                                _dragging = true;
                                _controlsVisible = true;
                              }),
                              onDrag: (value) => setState(() => _dragValue = value),
                              onEndDrag: (value) async {
                                await controller.seekTo(Duration(milliseconds: (value * 1000).round()));
                                setState(() => _dragging = false);
                                _scheduleHide();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.dragging,
    required this.dragValue,
    required this.onStartDrag,
    required this.onDrag,
    required this.onEndDrag,
    required this.fullscreen,
    this.onToggleFullscreen,
  });

  final VideoPlayerController controller;
  final bool dragging;
  final double dragValue;
  final VoidCallback onStartDrag;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onEndDrag;
  final bool fullscreen;
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final total = controller.value.duration.inMilliseconds;
    final value = dragging
        ? dragValue
        : (total == 0 ? 0.0 : (controller.value.position.inMilliseconds / total).clamp(0.0, 1.0));
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 18, 6, 2),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Color(0x99000000)],
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () async {
              if (controller.value.isPlaying) {
                await controller.pause();
              } else {
                await controller.play();
              }
            },
            icon: Icon(
              controller.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: value.clamp(0.0, 1.0),
                onChangeStart: (_) => onStartDrag(),
                onChanged: onDrag,
                onChangeEnd: onEndDrag,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '${_clock(controller.value.position)} / ${_clock(controller.value.duration)}',
              style: const TextStyle(color: Colors.white, fontSize: 11.5),
            ),
          ),
          if (onToggleFullscreen != null)
            IconButton(
              onPressed: onToggleFullscreen,
              icon: Icon(
                fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  static String _clock(Duration duration) {
    final total = duration.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
