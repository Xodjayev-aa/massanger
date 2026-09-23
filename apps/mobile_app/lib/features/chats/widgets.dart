import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;


/// Avatar for a user or chat.
///
/// `avatars` is the one bucket with a public read policy, so an avatar path is a
/// public URL — no signature round trip per list row. Chat media (photos, voice) is
/// private and signed by the repository instead; mixing those two up is the classic
/// way an avatar wall starts returning 403s.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.path,
    this.externalUrl,
    this.size = 44,
    this.isOnline = false,
  });

  final String name;
  final String? path;
  final String? externalUrl;
  final double size;
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final widget = _inner(context);
    if (!isOnline) return widget;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        widget,
        Positioned(
          right: -1,
          bottom: -1,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, shape: BoxShape.circle),
            child: Padding(
              padding: const EdgeInsets.all(1.5),
              child: Container(
                width: size * 0.24,
                height: size * 0.24,
                decoration: BoxDecoration(color: const Color(0xFF31C753), shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _inner(BuildContext context) {
    final url = _resolve();
    final scheme = Theme.of(context).colorScheme;
    if (url == null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: scheme.secondaryContainer, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(
          _initials(),
          style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSecondaryContainer, fontSize: size * 0.38),
        ),
      );
    }
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: (size * 3).round(),
          placeholder: (context, url) => ColoredBox(color: scheme.surfaceContainerHighest),
          errorWidget: (context, url, error) =>
              ColoredBox(color: scheme.secondaryContainer, child: Icon(Icons.person_rounded, size: size * 0.5)),
        ),
      ),
    );
  }

  String? _resolve() {
    final external = externalUrl;
    if (external != null && external.startsWith('http')) return external;
    final stored = path;
    if (stored == null || stored.isEmpty) return null;
    if (stored.startsWith('http')) return stored;
    return sb.Supabase.instance.client.storage.from('avatars').getPublicUrl(stored);
  }

  String _initials() {
    final parts = name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    String head(String value) => value.substring(0, 1).toUpperCase();
    if (parts.length == 1) return head(parts.first);
    return '${head(parts.first)}${head(parts.last)}';
  }
}

/// Small marker that a chat or message came through the Telegram bridge, plus the
/// account's current state when it matters (re-auth needed, syncing).
class TelegramBadge extends StatelessWidget {
  const TelegramBadge({super.key, this.authState, this.compact = false});

  final String? authState;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, colour, label) = switch (authState) {
      null || 'linked' => ('telegram', scheme.primary, 'Telegram'),
      'syncing' => ('sync', scheme.primary, 'Syncing'),
      'needs_reauth' => ('lock', scheme.error, 'Sign in again'),
      'revoked' => ('link_off', scheme.error, 'Disconnected'),
      'failed' => ('error', scheme.error, 'Bridge error'),
      'unlinked' => ('link_off', scheme.outline, 'Not linked'),
      _ => ('hourglass', scheme.tertiary, 'Telegram'),
    };
    final themed = switch (icon) {
      'telegram' => Icons.send_rounded,
      'sync' => Icons.sync_rounded,
      'lock' => Icons.lock_rounded,
      'link_off' => Icons.link_off_rounded,
      'error' => Icons.error_outline_rounded,
      _ => Icons.hourglass_top_rounded,
    };
    if (compact) {
      return Icon(themed, size: 16, color: colour);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withAlpha(26),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colour.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(themed, size: 13, color: colour),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: colour)),
        ],
      ),
    );
  }
}

class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: scheme.errorContainer.withAlpha(70), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
