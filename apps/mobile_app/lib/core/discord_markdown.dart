import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/router.dart';

/// Discord-style markdown and mention parser for messages and video captions.
/// Parses:
/// - `@username` mentions (styled with discord blue/blurple and clickable)
/// - `#channel` tags (styled with discord hashtag badge)
/// - `/video/:id` app video URLs (clickable and routed in-app)
/// - `**bold**`
/// - `*italic*`
/// - `~~strike~~`
/// - `__underline__`
/// - ```code blocks``` and `inline code`
class DiscordMarkdown {
  const DiscordMarkdown._();

  static final RegExp _videoRoutePattern = RegExp(r'^/video/([0-9a-fA-F-]{36})$');

  static String shareVideoUrl(String videoId) {
    final path = Routes.video(videoId);
    final base = Uri.base;
    if ((base.scheme == 'http' || base.scheme == 'https') && base.hasAuthority) {
      return '${base.origin}$path';
    }
    return path;
  }

  static String? _extractAppVideoId(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.hasScheme || uri.hasAuthority) {
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      final base = Uri.base;
      if ((base.scheme == 'http' || base.scheme == 'https') &&
          base.hasAuthority &&
          uri.origin != base.origin) {
        return null;
      }
    }
    final match = _videoRoutePattern.firstMatch(uri.path);
    return match?.group(1);
  }

  static List<InlineSpan> parse(
    String text, {
    required BuildContext context,
    TextStyle? style,
    void Function(String user)? onMentionTap,
    void Function(String channel)? onChannelTap,
    void Function(String videoId)? onVideoTap,
  }) {
    final theme = Theme.of(context);
    final baseStyle = style ?? theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final spans = <InlineSpan>[];

    // Regex matching code blocks, inline code, bold, italic, strike, underline,
    // app /video/:id links, @mentions, and #channels.
    final regex = RegExp(
      r'(`{3}[\s\S]*?`{3})|' // 1: code block
      r'(`[^`]+`)|' // 2: inline code
      r'(\*\*[^*]+\*\*)|' // 3: bold
      r'(\*[^*]+\*)|' // 4: italic
      r'(~~[^~]+~~)|' // 5: strikethrough
      r'(__[^_]+__)|' // 6: underline
      r'((?:https?://[^\s<>()]+)?/video/[0-9a-fA-F-]{36})\b|' // 7: /video/:id link
      r'(@[a-zA-Z0-9_.]+)|' // 8: @mention
      r'(#[a-zA-Z0-9_-]+)', // 9: #channel
      multiLine: true,
    );

    int lastIndex = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(text: text.substring(lastIndex, match.start), style: baseStyle));
      }

      final raw = match.group(0)!;
      if (match.group(1) != null) {
        // Multi-line code block ```code```
        final code = raw.substring(3, raw.length - 3).trim();
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(200),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(
              code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: Color(0xFF57F287)),
            ),
          ),
        ));
      } else if (match.group(2) != null) {
        // Inline `code`
        final code = raw.substring(1, raw.length - 1);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(160),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              code,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFFEB459E)),
            ),
          ),
        ));
      } else if (match.group(3) != null) {
        // **bold**
        spans.add(TextSpan(
          text: raw.substring(2, raw.length - 2),
          style: baseStyle.copyWith(fontWeight: FontWeight.w700),
        ));
      } else if (match.group(4) != null) {
        // *italic*
        spans.add(TextSpan(
          text: raw.substring(1, raw.length - 1),
          style: baseStyle.copyWith(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(5) != null) {
        // ~~strike~~
        spans.add(TextSpan(
          text: raw.substring(2, raw.length - 2),
          style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
        ));
      } else if (match.group(6) != null) {
        // __underline__
        spans.add(TextSpan(
          text: raw.substring(2, raw.length - 2),
          style: baseStyle.copyWith(decoration: TextDecoration.underline),
        ));
      } else if (match.group(7) != null) {
        // App /video/:id link
        final videoId = _extractAppVideoId(raw);
        if (videoId == null) {
          spans.add(TextSpan(text: raw, style: baseStyle));
        } else {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: InkWell(
              onTap: () {
                if (onVideoTap != null) {
                  onVideoTap(videoId);
                } else {
                  context.push(Routes.video(videoId));
                }
              },
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withAlpha(35),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.play_circle_outline_rounded, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        raw,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ));
        }
      } else if (match.group(8) != null) {
        // @mention
        final username = raw.substring(1);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: InkWell(
            onTap: () => onMentionTap?.call(username),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF5865F2).withAlpha(40),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                raw,
                style: const TextStyle(
                  color: Color(0xFF5865F2),
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ));
      } else if (match.group(9) != null) {
        // #channel
        final channel = raw.substring(1);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: InkWell(
            onTap: () => onChannelTap?.call(channel),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.blueGrey.withAlpha(50),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                raw,
                style: const TextStyle(
                  color: Color(0xFF3BA55D),
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ));
      }

      lastIndex = match.end;
    }

    if (lastIndex < text.length) {
      spans.add(TextSpan(text: text.substring(lastIndex), style: baseStyle));
    }

    return spans;
  }
}

/// Discord-styled role badge (e.g. [Admin #1337], [VIP], [Creator])
class DiscordRoleBadge extends StatelessWidget {
  const DiscordRoleBadge({
    super.key,
    required this.badge,
    this.colorHex,
    this.discriminator,
    this.compact = false,
  });

  final String badge;
  final String? colorHex;
  final int? discriminator;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    Color color = const Color(0xFF5865F2); // Discord Blurple
    if (colorHex != null && colorHex!.startsWith('#')) {
      final hex = colorHex!.replaceAll('#', '');
      if (hex.length == 6) {
        final parsed = int.tryParse('0xFF$hex');
        if (parsed != null) color = Color(parsed);
      }
    }

    final label = discriminator != null ? '$badge #$discriminator' : badge;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: compact ? 1 : 2),
      decoration: BoxDecoration(
        color: color.withAlpha(35),
        borderRadius: BorderRadius.circular(compact ? 4 : 6),
        border: Border.all(color: color.withAlpha(120), width: 0.9),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 10 : 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
