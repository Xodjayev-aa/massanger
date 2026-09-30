import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/discord_markdown.dart';
import '../../core/formatting.dart';
import '../../data/shorts_repository.dart';

/// Feed video card:
/// - 16:9 preview box with duration badge
/// - Author avatar and Discord role badge
/// - Video title, view count, timestamp
/// - Context menu for opening or copying the shareable `/video/:id` link
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    this.onTap,
  });

  final ShortVideo video;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap ?? () => context.push(Routes.video(video.id), extra: video),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 16:9 Thumbnail preview box with Duration chip
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Container(
                  color: const Color(0xFF0F0F0F),
                  child: Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 56,
                      color: Colors.white.withAlpha(220),
                    ),
                  ),
                ),
                // Gradient shade on bottom
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: <Color>[
                          Colors.black.withAlpha(180),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                // Duration Badge
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(210),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      ChatFormatting.duration(video.duration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Metadata row: Avatar + Details
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Channel Avatar
                CircleAvatar(
                  radius: 19,
                  backgroundColor: scheme.primaryContainer,
                  child: Text(
                    (video.authorName ?? 'U').substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimaryContainer,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Title + Channel Name + Discord Badge + Metrics
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        video.title ?? video.caption ?? 'Untitled Video',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              video.authorName ?? '@creator',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
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
                      const SizedBox(height: 2),
                      Text(
                        '${_formatViews(video.viewCount)} views • ${ChatFormatting.dayLabel(video.createdAt)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                // 3-dot context menu
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  onPressed: () {
                    final link = DiscordMarkdown.shareVideoUrl(video.id);
                    showModalBottomSheet<void>(
                      context: context,
                      builder: (sheetContext) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ListTile(
                              leading: const Icon(Icons.play_circle_outline_rounded),
                              title: const Text('Open Video'),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                context.push(Routes.video(video.id), extra: video);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.link_rounded),
                              title: const Text('Copy Video Link'),
                              subtitle: Text(link, maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () async {
                                await Clipboard.setData(ClipboardData(text: link));
                                if (!sheetContext.mounted) return;
                                Navigator.of(sheetContext).pop();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Video link copied to clipboard.')),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatViews(int views) {
    if (views < 1000) return '$views';
    if (views < 1000000) return '${(views / 1000).toStringAsFixed(1)}K';
    return '${(views / 1000000).toStringAsFixed(1)}M';
  }
}
