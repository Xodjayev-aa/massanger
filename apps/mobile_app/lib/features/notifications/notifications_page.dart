import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/feed_repository.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';

/// Everything that happened while you were away, in one list.
///
/// The row is built from the notification's `kind` plus whatever id it carries,
/// which is why one page can cover a like on a reel, a comment on a video, a
/// follow request, a gift, a bot broadcast and a payment receipt without a
/// per-kind screen.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final List<NotificationItem> _items = <NotificationItem>[];
  final Map<String, List<TagSummary>> _tags = <String, List<TagSummary>>{};
  bool _loading = true;
  bool _exhausted = false;
  Object? _error;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({required bool reset}) async {
    setState(() {
      if (reset) _loading = _items.isEmpty;
      _error = null;
      if (reset) _exhausted = false;
    });
    final cursor = reset || _items.isEmpty ? null : _items.last.createdAt;
    try {
      final page = await sl<FeedRepository>().notifications(before: cursor);
      final actorIds = page.map((n) => n.actorId).whereType<String>();
      final tags = actorIds.isEmpty
          ? const <String, List<TagSummary>>{}
          : await sl<SocialRepository>().tagsFor(actorIds);
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page);
        _tags.addAll(tags);
        _exhausted = page.isEmpty;
        _loading = false;
      });
      // Opening the list is the read receipt; the badge clears in the same
      // breath, so the shell never shows a count the user has already seen.
      if (reset) {
        unawaited(sl<FeedRepository>().markNotificationsRead().catchError((Object _) {}));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<NotificationItem> get _visible {
    if (_filter == 'all') return _items;
    if (_filter == 'mentions') {
      return _items.where((n) => n.kind == 'mention' || n.kind == 'reply' || n.kind == 'comment').toList();
    }
    if (_filter == 'follows') return _items.where((n) => n.kind.startsWith('follow')).toList();
    return _items.where((n) => n.kind == 'gift' || n.kind == 'payment' || n.kind == 'system').toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await sl<FeedRepository>().markNotificationsRead().catchError((Object _) {});
              if (mounted) setState(() => _items.setAll(0, <NotificationItem>[]));
              await _load(reset: true);
            },
            child: const Text('Mark all read'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                for (final entry in const <String, String>{
                  'all': 'All',
                  'mentions': 'Comments',
                  'follows': 'Follows',
                  'money': 'Gifts',
                }.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: _filter == entry.key,
                      onSelected: (_) => setState(() => _filter = entry.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _items.isEmpty
              ? EmptyState(
                  title: 'Activity could not load',
                  message: _error is AppException ? (_error! as AppException).message : 'Check your connection.',
                  icon: Icons.notifications_off_outlined,
                  action: FilledButton(onPressed: () => _load(reset: true), child: const Text('Retry')),
                )
              : _visible.isEmpty
                  ? const EmptyState(
                      title: 'Nothing new',
                      message: 'Likes, comments, follows and gifts land here.',
                      icon: Icons.notifications_none_rounded,
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(reset: true),
                      child: ListView.separated(
                        itemCount: _visible.length,
                        separatorBuilder: (_, __) => const Divider(height: 1, indent: 66),
                        itemBuilder: (context, index) {
                          final item = _visible[index];
                          return _NotificationRow(
                            item: item,
                            tags: _tags[item.actorId] ?? const <TagSummary>[],
                            onTap: () => _open(item),
                          );
                        },
                      ),
                    ),
    );
  }

  Future<void> _open(NotificationItem item) async {
    final router = GoRouter.of(context);
    switch (item.kind) {
      case 'follow':
      case 'follow_request':
      case 'follow_accepted':
        if (item.actorId != null) router.push(Routes.user(item.actorId!));
      case 'gift':
      case 'payment':
      case 'system':
        router.push(Routes.wallet);
      case 'new_short':
      case 'short_like':
      case 'short_comment':
        if (item.shortId != null) router.push(Routes.shortWatch(item.shortId!));
      case 'message':
      case 'mention':
        if (item.chatId != null) router.push(Routes.chat(item.chatId!));
      default:
        if (item.videoId != null) {
          router.push(Routes.watch(item.videoId!));
        } else if (item.shortId != null) {
          router.push(Routes.shortWatch(item.shortId!));
        } else if (item.chatId != null) {
          router.push(Routes.chat(item.chatId!));
        }
    }
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.item, required this.tags, required this.onTap});

  final NotificationItem item;
  final List<TagSummary> tags;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (item.kind) {
      'follow' || 'follow_request' || 'follow_accepted' => (Icons.person_add_alt_1_rounded, Brand.seed),
      'like' || 'short_like' => (Icons.favorite_rounded, Brand.accent),
      'comment' || 'reply' || 'short_comment' => (Icons.mode_comment_rounded, Brand.seed),
      'gift' => (Icons.card_giftcard_rounded, Brand.gold),
      'payment' => (Icons.receipt_long_rounded, Brand.gold),
      'mention' => (Icons.alternate_email_rounded, Brand.seed),
      'message' => (Icons.forum_rounded, Brand.seed),
      _ => (Icons.notifications_rounded, scheme.onSurfaceVariant),
    };
    final unread = item.readAt == null;
    return ListTile(
      onTap: onTap,
      tileColor: unread ? scheme.primary.withOpacity(0.05) : null,
      leading: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          PersonAvatar(
            name: item.actorName ?? 'MessengerX',
            path: item.actorAvatarPath,
            size: 40,
          ),
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: scheme.surface, width: 2)),
              child: Icon(icon, size: 11, color: Colors.white),
            ),
          ),
        ],
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: NameLine(
              name: item.actorName ?? 'MessengerX',
              handle: item.actorUsername == null ? null : handleOf(item.actorUsername, item.actorDiscriminator),
              tags: tags,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${_sentence(item)} · ${relativeTime(item.createdAt)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      ),
      trailing: unread ? const CircleAvatar(radius: 4, backgroundColor: Brand.seed) : null,
    );
  }

  static String _sentence(NotificationItem item) {
    final who = item.actorName ?? 'Someone';
    return switch (item.kind) {
      'follow' => '$who started following you',
      'follow_request' => '$who asked to follow you',
      'follow_accepted' => '$who accepted your follow request',
      'like' => '$who liked your video',
      'short_like' => '$who liked your reel',
      'comment' => '$who commented on your video',
      'short_comment' => '$who commented on your reel',
      'reply' => '$who replied to your comment',
      'mention' => '$who mentioned you',
      'message' => '$who sent you a message',
      'gift' => '$who sent you a gift',
      'payment' => 'Your payment went through',
      'new_short' => '$who posted a new reel',
      'system' => '${item.payload['message'] ?? 'A system update'}',
      _ => '$who did something on your account',
    };
  }
}
