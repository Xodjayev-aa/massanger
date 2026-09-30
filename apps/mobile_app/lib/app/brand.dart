import 'package:flutter/material.dart';

import '../data/social_models.dart';

/// The brand: one mark, one wordmark, one accent gradient.
///
/// The logo is a geometric placeholder, not a mascot: a rounded square holding
/// an abstract **M** whose middle stroke is a play triangle. It reads at 20 px
/// in a nav bar and at 200 px on a splash, and it is drawn with a painter rather
/// than shipped as a PNG, so it stays crisp at every density and costs no
/// asset — which also means it works in both themes without a second file.
class Brand {
  const Brand._();

  static const Color seed = Color(0xFF4C6FFF);
  static const Color accent = Color(0xFFFF2E63);
  static const Color live = Color(0xFFFF3B30);
  static const Color gold = Color(0xFFFFB300);
  static const Color verified = Color(0xFF1D9BF0);

  static const LinearGradient gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF4C6FFF), Color(0xFF7A5CFF), Color(0xFFFF2E63)],
  );

  static const LinearGradient subtle = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0x224C6FFF), Color(0x22FF2E63)],
  );
}

/// The mark. [size] is the square's side.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32, this.onDark});

  final double size;

  /// Force the ink colour instead of following the theme.
  final bool? onDark;

  @override
  Widget build(BuildContext context) {
    final dark = onDark ?? Theme.of(context).brightness == Brightness.dark;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(dark: dark)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.width * 0.28);
    final rect = Offset.zero & size;
    final background = Paint()
      ..shader = Brand.gradient.createShader(rect)
      ..isAntiAlias = true;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), background);

    final ink = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.11
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // Two legs of an M, then a play triangle where the middle stroke would be.
    final left = size.width * 0.26;
    final right = size.width * 0.74;
    final top = size.height * 0.28;
    final bottom = size.height * 0.74;
    canvas.drawLine(Offset(left, bottom), Offset(left, top), stroke);
    canvas.drawLine(Offset(right, bottom), Offset(right, top), stroke);

    final triangle = Path()
      ..moveTo(size.width * 0.40, size.height * 0.34)
      ..lineTo(size.width * 0.40, size.height * 0.68)
      ..lineTo(size.width * 0.66, size.height * 0.51)
      ..close();
    canvas.drawPath(triangle, ink);
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => oldDelegate.dark != dark;
}

/// Mark + wordmark, for app bars and the splash.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.size = 30, this.showWordmark = true});

  final double size;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        BrandMark(size: size),
        if (showWordmark) ...<Widget>[
          SizedBox(width: size * 0.3),
          Text(
            'MessengerX',
            style: TextStyle(
              fontSize: size * 0.62,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              color: scheme.onSurface,
            ),
          ),
        ],
      ],
    );
  }
}

/// The blue tick. Used next to a name, never on its own.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) => Icon(Icons.verified_rounded, size: size, color: Brand.verified);
}

/// A custom profile tag, rendered exactly as it is stored: text, emoji and the
/// style bits the buyer picked. Kept tiny so a name line can hold three of them.
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.tag, this.compact = false});

  final TagSummary tag;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final start = _color(tag.style['bg_start'] ?? tag.style['color'], scheme.primary);
    final end = _color(tag.style['bg_end'], start);
    final foreground = _color(tag.style['fg'] ?? tag.style['text_color'], Colors.white);
    final label = tag.emoji == null || tag.emoji!.isEmpty ? tag.text : '${tag.emoji} ${tag.text}';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: compact ? 1 : 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: <Color>[start, end]),
        borderRadius: BorderRadius.circular(6),
        border: tag.style['border'] == true ? Border.all(color: foreground.withOpacity(0.5)) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: compact ? 9.5 : 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  static Color _color(Object? raw, Color fallback) {
    if (raw is! String) return fallback;
    var value = raw.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) value = 'FF$value';
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }
}

/// A pinned/owned cosmetic badge (colored dot or emoji) for a profile line.
class BadgePill extends StatelessWidget {
  const BadgePill({super.key, required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Brand.seed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[Icon(icon, size: 11, color: tint), const SizedBox(width: 4)],
          Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: tint)),
        ],
      ),
    );
  }
}

/// A name line: handle, tags, tick — the same everywhere a person is shown, so
/// two screens can never disagree about what a user looks like.
class NameLine extends StatelessWidget {
  const NameLine({
    super.key,
    required this.name,
    this.handle,
    this.tags = const <TagSummary>[],
    this.verified = false,
    this.maxTags = 2,
    this.style,
    this.secondary,
  });

  final String name;
  final String? handle;
  final List<TagSummary> tags;
  final bool verified;
  final int maxTags;
  final TextStyle? style;
  final String? secondary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style ?? TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
          ),
        ),
        if (verified) ...<Widget>[const SizedBox(width: 4), const VerifiedBadge()],
        if (tags.isNotEmpty) ...<Widget>[
          const SizedBox(width: 6),
          for (final tag in tags.take(maxTags)) ...<Widget>[
            TagChip(tag: tag, compact: true),
            const SizedBox(width: 4),
          ],
        ],
        if (secondary != null)
          Flexible(
            child: Text(
              secondary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// A filled pill button used for follow/subscribe actions.
class FollowButton extends StatelessWidget {
  const FollowButton({
    super.key,
    required this.following,
    required this.onPressed,
    this.pending = false,
    this.compact = false,
  });

  final bool following;
  final bool pending;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = pending ? 'Requested' : (following ? 'Following' : 'Follow');
    if (following || pending) {
      return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, compact ? 32 : 38),
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: Size(0, compact ? 32 : 38),
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

/// `@ada#0000` — the Discord-style handle. The discriminator is zero-padded the
/// way the database stores it, and a missing username degrades to `@user` rather
/// than to an empty string.
String handleOf(String? username, [int? discriminator]) {
  final name = (username == null || username.trim().isEmpty) ? 'user' : username.trim();
  if (discriminator == null) return '@$name';
  return '@$name#${discriminator.toString().padLeft(4, '0')}';
}

/// Renders a counter the way a feed does: 940 → 940, 12.4k → 12.4K.
String compactCount(int value) {
  if (value < 1000) return '$value';
  if (value < 10000) return '${(value / 1000).toStringAsFixed(1)}K';
  if (value < 1000000) return '${(value / 1000).round()}K';
  if (value < 10000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  return '${(value / 1000000).round()}M';
}

/// `3:07` — duration badges and player chrome.
String clockDuration(Duration duration) {
  final total = duration.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = hours > 0 ? minutes.toString().padLeft(2, '0') : '$minutes';
  return hours > 0
      ? '$hours:$mm:${seconds.toString().padLeft(2, '0')}'
      : '$mm:${seconds.toString().padLeft(2, '0')}';
}

/// `2 days ago`, `5 hours ago` — feed timestamps.
String relativeTime(DateTime value) {
  final delta = DateTime.now().toUtc().difference(value.toUtc());
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) return '${delta.inHours} h ago';
  if (delta.inDays < 7) return '${delta.inDays} d ago';
  if (delta.inDays < 30) return '${(delta.inDays / 7).floor()} w ago';
  if (delta.inDays < 365) return '${(delta.inDays / 30).floor()} mo ago';
  return '${(delta.inDays / 365).floor()} y ago';
}

/// The gradient ring used around a live avatar.
class GradientRing extends StatelessWidget {
  const GradientRing({super.key, required this.child, this.size = 52, this.padding = 2.4});

  final Widget child;
  final double size;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(padding),
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: Brand.gradient),
      child: child,
    );
  }
}

/// Empty states, in one place so every tab looks like the same product.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.message, this.icon = Icons.explore_off_rounded, this.action});

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 46, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            if (message != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ],
            if (action != null) ...<Widget>[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}
