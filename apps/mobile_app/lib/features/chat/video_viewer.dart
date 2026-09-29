import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Full-screen playback for one clip: the tap that opened it is the user
/// gesture that lets sound play, so the viewer starts unmuted and in control.
///
/// Deliberately no control-deck dependency (chewie and friends would pull a
/// second player stack into the tree): `video_player`'s own progress indicator
/// covers Phase-1 scrubbing, and the overlay keeps the chrome the feed wants.
class VideoViewer extends StatefulWidget {
  const VideoViewer({super.key, required this.url, required this.duration});

  final String url;

  /// Shown only while loading (the position line flips to the controller's
  /// real duration as soon as it is known).
  final Duration duration;

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _muted = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    // Ownership discipline: `fresh` is non-null until the controller is handed
    // to `_controller`. Whatever leaves this method still holding `fresh` is
    // disposed exactly once here; after the hand-over the State's dispose owns
    // it — so a play() failure cannot double-dispose.
    VideoPlayerController? fresh;
    try {
      fresh = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await fresh.initialize();
      if (!mounted) return;
      fresh.addListener(_onTick);
      _controller = fresh;
      fresh = null;
      setState(() {});
      await _controller?.play();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      try {
        await fresh?.dispose();
      } catch (_) {
        // A controller that failed before initialize() still wants a best-effort
        // dispose; a platform exception there must not escape initState.
      }
    }
  }

  void _onTick() {
    // Only play state and position live in this subtree; a full-screen player
    // rebuilding at frame rate is the cheapest correct option.
    if (mounted) setState(() {});
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
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
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      controller.dispose();
    }
    super.dispose();
  }

  String _position(Duration value) {
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Video'),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: _error != null
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'This video could not be played.',
                          style: TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : controller == null
                        ? const CircularProgressIndicator()
                        : GestureDetector(
                            onTap: _togglePlay,
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio <= 0
                                  ? 16 / 9
                                  : controller.value.aspectRatio,
                              child: VideoPlayer(controller),
                            ),
                          ),
              ),
            ),
            if (controller != null && _error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: _togglePlay,
                      icon: Icon(
                        controller.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      onPressed: _toggleMute,
                      icon: Icon(
                        _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _position(controller.value.position),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Color(0xFF4F8DFF),
                          bufferedColor: Color(0x55FFFFFF),
                          backgroundColor: Color(0x33FFFFFF),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                    Text(
                      _position(controller.value.duration),
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
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
