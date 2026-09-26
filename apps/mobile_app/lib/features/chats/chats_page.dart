import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';
import 'chats_bloc.dart';
import 'widgets.dart';

/// The chat list. It doubles as the app's home: the Telegram bridge status lives in
/// the app bar, and the unread total is the number the user actually cares about.
class ChatsPage extends StatelessWidget {
  const ChatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MessengerX'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => context.push(Routes.search),
          ),
          const _TelegramAction(),
          IconButton(
            tooltip: 'You',
            icon: const Icon(Icons.account_circle_rounded),
            onPressed: () => context.push(Routes.profile),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(Routes.newChat()),
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New chat'),
      ),
      body: SafeArea(
        child: BlocBuilder<ChatsBloc, ChatsState>(
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
            final chats = state.visible;
            return RefreshIndicator(
              onRefresh: () async => context.read<ChatsBloc>().refresh(),
              child: chats.isEmpty
                  ? _EmptyList(hasQuery: state.query.trim().isNotEmpty)
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: chats.length,
                      separatorBuilder: (context, index) => const Divider(indent: 74, height: 1),
                      itemBuilder: (context, index) => ChatTile(chat: chats[index]),
                    ),
            );
          },
        ),
      ),
    );
  }
}

String _failureText(Object? error) {
  final wrapped = error;
  if (wrapped is AppException) return wrapped.message;
  return 'Could not load your chats.';
}

class _TelegramAction extends StatefulWidget {
  const _TelegramAction();

  @override
  State<_TelegramAction> createState() => _TelegramActionState();
}

class _TelegramActionState extends State<_TelegramAction> {
  String? _authState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await context.read<TelegramRepository>().status();
      if (mounted) setState(() => _authState = status.authState);
    } catch (_) {
      // The badge is decoration; a failure here must not show anything alarming.
    }
  }

  String get _tooltip {
    return switch (_authState) {
      'linked' => 'Telegram — linked',
      'syncing' => 'Telegram — syncing',
      'needs_reauth' => 'Telegram — sign in again',
      'revoked' => 'Telegram — disconnected',
      'failed' => 'Telegram — bridge error',
      'unlinked' => 'Telegram — not linked',
      null => 'Telegram',
      _ => 'Telegram — ${_authState!}',
    };
  }

  bool get _needsAttention {
    final state = _authState;
    if (state == null) return false;
    return state != 'linked' && state != 'unlinked';
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _tooltip,
      onPressed: () async {
        await context.push(Routes.telegram);
        if (context.mounted) await _refresh();
      },
      icon: Badge(
        isLabelVisible: _needsAttention,
        label: const Text('!'),
        backgroundColor: Theme.of(context).colorScheme.error,
        child: TelegramBadge(authState: _authState, compact: true),
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat});

  final ChatSummary chat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = chat.displayName;
    final preview = chat.previewKind == 'image'
        ? 'Photo${chat.previewBody == null || chat.previewBody!.isEmpty ? '' : ': ${chat.previewBody}'}'
        : chat.subtitle;

    return ListTile(
      onTap: () => context.push(Routes.chat(chat.chatId)),
      leading: PersonAvatar(
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
  const _EmptyList({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: <Widget>[
        const SizedBox(height: 96),
        Icon(Icons.forum_rounded, size: 42, color: theme.colorScheme.outline),
        const SizedBox(height: 14),
        Text(
          hasQuery ? 'No chat matches that.' : 'No conversations yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          hasQuery ? 'Try a name from the search tab.' : 'Start one, or connect Telegram in Settings to mirror your chats.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
