import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/di.dart';
import '../../core/errors.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../../data/voice_service.dart';
import '../auth/auth_bloc.dart';
import '../chats/chats_bloc.dart';
import '../chats/search_page.dart';
import '../chats/widgets.dart';
import 'chat_bloc.dart';
import 'composer.dart';
import 'message_bubble.dart';

/// A single conversation.
///
/// The list is reversed (`rendered` is newest-first) which is what makes "load older"
/// a scroll-to-edge action instead of a button, and keeps the viewport pinned to the
/// newest message when one arrives.
class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.chatId});

  /// The open thread never gets a foreground banner: the bubble itself is the
  /// notification. Cleared when its scaffold is disposed by the router.
  static final ValueNotifier<String?> openChatId = ValueNotifier<String?>(null);

  final String chatId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ChatBloc>(
      create: (context) => ChatBloc(
        sl<ChatRepository>(),
        sl<VoiceService>(),
        auth: context.read<AuthBloc>(),
        player: sl<VoicePlayer>(),
      )..add(ChatOpened(chatId)),
      child: _ChatScaffold(chatId: chatId),
    );
  }
}

class _ChatScaffold extends StatefulWidget {
  const _ChatScaffold({required this.chatId});

  final String chatId;

  @override
  State<_ChatScaffold> createState() => _ChatScaffoldState();
}

class _ChatScaffoldState extends State<_ChatScaffold> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    ChatPage.openChatId.value = widget.chatId;
  }

  @override
  void didUpdateWidget(covariant _ChatScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.chatId != oldWidget.chatId) ChatPage.openChatId.value = widget.chatId;
  }

  @override
  void dispose() {
    if (ChatPage.openChatId.value == widget.chatId) ChatPage.openChatId.value = null;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Loading older history is triggered by the trailing edge of a reversed list.
    if (_scroll.position.maxScrollExtent - _scroll.position.pixels < 600) {
      context.read<ChatBloc>().add(const ChatOlderRequested());
    }
  }

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<ChatBloc>();
    return BlocBuilder<ChatBloc, ChatState>(
      builder: (context, state) {
        final title = _titleOf(context, state);
        final muted = context.select<ChatsBloc, bool>((chats) =>
            chats.state.chats.any((chat) => chat.chatId == widget.chatId && chat.isMuted));
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 6,
            title: Row(
              children: <Widget>[
                PersonAvatar(name: title, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      if (state.typingLabel != null)
                        Text(state.typingLabel!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
                    ],
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: muted ? 'Unmute this chat' : 'Mute this chat for 8 hours',
                icon: Icon(muted ? Icons.notifications_off_rounded : Icons.notifications_active_outlined),
                onPressed: () => _setMuted(!muted),
              ),
              IconButton(
                tooltip: 'Search in this chat',
                icon: const Icon(Icons.search_rounded),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => SearchPage(chatId: state.chatId)),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: InlineError(
                      message: _errorText(state.error),
                      onRetry: state.status == ChatStatus.failure ? () => bloc.add(ChatOpened(state.chatId)) : null,
                    ),
                  ),
                Expanded(
                  child: state.status == ChatStatus.loading
                      ? const Center(child: CircularProgressIndicator())
                      : _Thread(scroll: _scroll, state: state, bloc: bloc),
                ),
                Composer(bloc: bloc, chatId: state.chatId),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _setMuted(bool muted) async {
    try {
      await sl<ChatRepository>().setMuted(widget.chatId, muted);
      if (!mounted) return;
      await context.read<ChatsBloc>().refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(muted ? 'Muted for 8 hours.' : 'Chat unmuted.')),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error is AppException ? error.message : 'Could not change the chat mute.')),
      );
    }
  }

  /// The chat list already knows the display name, so the header uses it rather than
  /// showing a truncated id while the feed loads.
  static String _titleOf(BuildContext context, ChatState state) {
    final chatId = state.chatId;
    if (chatId.isEmpty) return 'Chat';
    final summary = context
        .read<ChatsBloc>()
        .state
        .chats
        .where((chat) => chat.chatId == chatId)
        .toList(growable: false);
    return summary.isEmpty ? 'Conversation' : summary.first.displayName;
  }

  static String _errorText(Object? error) => error is AppException ? error.message : '$error';
}

class _Thread extends StatelessWidget {
  const _Thread({required this.scroll, required this.state, required this.bloc});

  final ScrollController scroll;
  final ChatState state;
  final ChatBloc bloc;

  @override
  Widget build(BuildContext context) {
    final messages = state.rendered;
    return ListView.separated(
      controller: scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      itemCount: messages.length,
      separatorBuilder: (context, index) => const SizedBox(height: 3),
      itemBuilder: (context, index) {
        final message = messages[index];
        final previous = index + 1 < messages.length ? messages[index + 1] : null;
        // Group consecutive messages from the same sender within two minutes, like
        // every chat app does — and only drop the avatar, never the timestamp.
        final grouped = previous != null &&
            previous.isMine == message.isMine &&
            previous.senderName == message.senderName &&
            message.timestamp.difference(previous.timestamp).inSeconds.abs() < 120;
        return MessageBubble(
          message: message,
          showAvatar: !grouped,
          onTapReply: () => bloc.add(ChatReplyChosen(message)),
          onLongPress: () => _menu(context, message),
        );
      },
    );
  }

  Future<void> _menu(BuildContext context, MessageItem message) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                bloc.add(ChatReplyChosen(message));
              },
            ),
            if (message.isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Delete for everyone'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  bloc.add(ChatDeleteRequested(message.id));
                },
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}
