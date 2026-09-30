import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/models.dart';
import 'chats_bloc.dart';
import 'widgets.dart';

/// The chat list. It doubles as the app's messaging tab: with dual views for
/// Direct Messages (Telegram-style) and Servers/Channels (Discord-style).
class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key});

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TabBar(
          controller: _tabController,
          indicatorColor: scheme.primary,
          indicatorWeight: 3,
          labelColor: scheme.onSurface,
          unselectedLabelColor: scheme.onSurfaceVariant,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          tabs: const <Widget>[
            Tab(
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.send_rounded, size: 16),
                  SizedBox(width: 6),
                  Text('Direct Chats (Telegram)'),
                ],
              ),
            ),
            Tab(
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.tag_rounded, size: 16),
                  SizedBox(width: 6),
                  Text('Servers & Channels (Discord)'),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(Routes.newChat()),
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New chat'),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: <Widget>[
            // Tab 1: Telegram-style Direct Chats
            _buildChatsList(context, isServerView: false),
            // Tab 2: Discord-style Servers & Channels
            _buildChatsList(context, isServerView: true),
          ],
        ),
      ),
    );
  }

  Widget _buildChatsList(BuildContext context, {required bool isServerView}) {
    return BlocBuilder<ChatsBloc, ChatsState>(
      builder: (context, state) {
        if (state.isLoading) return const Center(child: CircularProgressIndicator());
        if (state.status == ChatsStatus.failure) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: <Widget>[
                InlineError(
                  message: _failureText(state.error),
                  onRetry: () => context.read<ChatsBloc>().add(const ChatsRefreshRequested()),
                ),
              ],
            ),
          );
        }
        final allChats = state.visible;
        final filteredChats = allChats.where((c) {
          if (isServerView) {
            return c.kind == ChatKind.group;
          } else {
            return c.kind == ChatKind.direct;
          }
        }).toList();

        return RefreshIndicator(
          onRefresh: () async => context.read<ChatsBloc>().refresh(),
          child: filteredChats.isEmpty
              ? _EmptyList(
                  hasQuery: state.query.trim().isNotEmpty,
                  isServerView: isServerView,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: filteredChats.length,
                  separatorBuilder: (context, index) => const Divider(indent: 74, height: 1),
                  itemBuilder: (context, index) => ChatTile(chat: filteredChats[index], isServerView: isServerView),
                ),
        );
      },
    );
  }
}

String _failureText(Object? error) {
  final wrapped = error;
  if (wrapped is AppException) return wrapped.message;
  return 'Could not load your chats.';
}

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat, this.isServerView = false});

  final ChatSummary chat;
  final bool isServerView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = isServerView ? '#${chat.displayName.replaceAll(' ', '-').toLowerCase()}' : chat.displayName;
    final preview = chat.previewKind == 'image'
        ? 'Photo${chat.previewBody == null || chat.previewBody!.isEmpty ? '' : ': ${chat.previewBody}'}'
        : chat.subtitle;

    return ListTile(
      onTap: () => context.push(Routes.chat(chat.chatId)),
      leading: isServerView
          ? Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF5865F2).withAlpha(35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF5865F2).withAlpha(80)),
              ),
              child: const Icon(Icons.tag_rounded, color: Color(0xFF5865F2)),
            )
          : PersonAvatar(
              name: name,
              path: chat.avatar ?? chat.peerAvatarPath,
              isOnline: chat.peerIsOnline,
            ),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (chat.isTelegramMirror)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Tooltip(
                message: 'Telegram',
                child: TelegramBadge(compact: true),
              ),
            ),
          const SizedBox(width: 6),
          Text(
            chat.lastMessageAt == null ? '' : ChatFormatting.listStamp(chat.lastMessageAt!),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      subtitle: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: chat.unreadCount > 0 ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (chat.isMuted) const Icon(Icons.notifications_off_rounded, size: 15),
          if (chat.unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: chat.isMuted ? theme.colorScheme.outline : theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                chat.unreadCount > 99 ? '99+' : '${chat.unreadCount}',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: theme.colorScheme.onPrimary),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.hasQuery, this.isServerView = false});

  final bool hasQuery;
  final bool isServerView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: <Widget>[
        const SizedBox(height: 96),
        Icon(isServerView ? Icons.tag_rounded : Icons.forum_rounded, size: 42, color: theme.colorScheme.outline),
        const SizedBox(height: 14),
        Text(
          hasQuery
              ? 'No matches found.'
              : isServerView
                  ? 'No community channels yet.'
                  : 'No conversations yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          hasQuery
              ? 'Try searching from the universal search bar.'
              : isServerView
                  ? 'Community group channels will appear here.'
                  : 'Start a direct chat, or link Telegram in Settings to mirror your conversations.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
