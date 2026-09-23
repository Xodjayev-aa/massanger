import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

/// Full-screen image viewer for a run of photos inside one thread.
///
/// The gallery receives the whole set of images in the conversation so a swipe
/// moves between photos instead of back to the thread — the one gesture people
/// expect from a chat app.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.urls, required this.index, this.titles});

  final List<String> urls;
  final int index;
  final List<String?>? titles;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController _controller = PageController(initialPage: widget.index.clamp(0, widget.urls.length - 1));
  late int _page = widget.index;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          PhotoViewGallery.builder(
            pageController: _controller,
            itemCount: widget.urls.length,
            builder: (context, index) => PhotoViewGalleryPageOptions(
              imageProvider: NetworkImage(widget.urls[index]),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 2.5,
              heroAttributes: PhotoViewHeroAttributes(tag: 'photo-$index'),
            ),
            scrollPhysics: const BouncingScrollPhysics(),
            onPageChanged: (index) => setState(() => _page = index),
          ),
          if (widget.urls.length > 1)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Text(
                '${_page + 1} / ${widget.urls.length}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 6,
            left: 4,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
