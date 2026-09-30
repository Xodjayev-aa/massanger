import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../data/media_cache.dart';
import '../../data/social_models.dart';
import '../chats/widgets.dart';

/// One long-form video, rendered the way a YouTube home grid item is: a 16:9
/// poster with the duration in the corner and a resume bar under it, then the
/// channel line and the numbers.
class VideoTile extends StatelessWidget {
  const VideoTile({
    super.key,
    required this.video,
    required this.media,
    this.tags = const <TagSummary>[],
    this.showAuthor = true,
    this.onTap,
    this.menu,
    this.watchLater = false,
    this.onWatchLater,
  });

  final VideoCard video;
  final MediaCache media;
  final List<TagSummary> tags;
  final bool showAuthor;
  final VoidCallback? onTap;
  final Widget? menu;
  final bool watchLater;
  final VoidCallback? onWatchLater;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap ?? () => context.push('/watch/${video.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Poster(video: video, media: media),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (showAuthor)
                  GestureDetector(
                    onTap: () => context.push('/u/${video.authorId}'),
                    child: PersonAvatar(
                      name: video.authorName ?? 'Someone',
                      path: video.authorAvatarPath,
                      size: 36,
                    ),
                  ),
                if (showAuthor) const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, height: 1.25),
                      ),
                      const SizedBox(height: 4),
                      if (showAuthor)
                        NameLine(
                          name: video.authorName ?? 'Someone',
                          handle: video.authorHandle,
                          tags: tags,
                          verified: video.authorVerified,
                          maxTags: 1,
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        '${compactCount(video.viewCount)} views · ${relativeTime(video.publishedAt)}',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (onWatchLater != null)
                  IconButton(
                    tooltip: watchLater ? 'Remove from Watch later' : 'Save to Watch later',
                    onPressed: onWatchLater,
                    icon: Icon(
                      watchLater ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (menu != null) menu!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Poster extends StatefulWidget {
  const _Poster({required this.video, required this.media});

  final VideoCard video;
  final MediaCache media;

  @override
  State<_Poster> createState() => _PosterState();
}

class _PosterState extends State<_Poster> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_Poster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.thumbnailKey != widget.video.thumbnailKey) _resolve();
  }

  Future<void> _resolve() async {
    final url = await widget.media.url(widget.video.thumbnailKey);
    if (url != null && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = widget.media.peek(widget.video.thumbnailKey);
    final progress = widget.video.duration.inMilliseconds == 0
        ? 0.0
        : (widget.video.progress.inMilliseconds / widget.video.duration.inMilliseconds).clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(0),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (url == null)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      scheme.surfaceContainerHighest,
                      scheme.surfaceContainerHighest.withOpacity(0.6),
                    ],
                  ),
                ),
                child: Center(
                  child: Icon(Icons.play_circle_outline_rounded, size: 42, color: scheme.onSurfaceVariant.withOpacity(0.7)),
                ),
              )
            else
              CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (context, _) => ColoredBox(color: scheme.surfaceContainerHighest),
                errorWidget: (context, _, __) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
                ),
              ),
            if (widget.video.duration > Duration.zero)
              Positioned(
                right: 8,
                bottom: 8,
                child: _Chip(label: clockDuration(widget.video.duration)),
              ),
            if (widget.video.visibility == 'followers')
              const Positioned(left: 8, bottom: 8, child: _Chip(label: 'Followers')),
            if (progress > 0.02)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.black26,
                  valueColor: const AlwaysStoppedAnimation<Color>(Brand.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.78), borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// The compact row used on the watch page's sidebar, the profile grid list and
/// search results: poster on the left, two lines of text on the right.
class VideoRowTile extends StatelessWidget {
  const VideoRowTile({super.key, required this.video, required this.media, this.onTap, this.trailing});

  final VideoCard video;
  final MediaCache media;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap ?? () => context.push('/watch/${video.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 148,
                height: 83,
                child: _Thumbnail(video: video, media: media),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.25),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.authorName ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${compactCount(video.viewCount)} views · ${relativeTime(video.publishedAt)}',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.video, required this.media});

  final VideoCard video;
  final MediaCache media;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  @override
  void initState() {
    super.initState();
    widget.media.url(widget.video.thumbnailKey).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = widget.media.peek(widget.video.thumbnailKey);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (url == null)
          ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Icon(Icons.play_circle_outline_rounded, color: scheme.onSurfaceVariant),
          )
        else
          CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
        if (widget.video.duration > Duration.zero)
          Positioned(
            right: 5,
            bottom: 5,
            child: _Chip(label: clockDuration(widget.video.duration)),
          ),
      ],
    );
  }
}
