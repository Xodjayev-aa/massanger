import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/formatting.dart';
import '../data/telegram_repository.dart';
import '../features/auth/auth_bloc.dart';
import '../features/chat/chat_page.dart';
import '../features/chats/chats_bloc.dart';

/// A foreground-only banner host, above the router so a message in *any* thread
/// can be noticed while the app is alive. This does not schedule an OS notification
/// and cannot wake a suspended iOS/Android app; the TDLib → Saved Messages queue
/// does that job. The unread count and chat feed remain the in-app source of truth.
///
/// The server is consulted before showing a banner: Realtime can race with a read
/// or mute, and a second device may have disabled previews. If those checks fail,
/// silence wins over displaying content the user asked to hide.
class IncomingNotices extends StatefulWidget {
  const IncomingNotices({
    super.key,
    required this.auth,
    required this.chats,
    required this.telegram,
    required this.client,
    required this.child,
  });

  final AuthBloc auth;
  final ChatsBloc chats;
  final TelegramRepository telegram;
  final SupabaseClient client;
  final Widget child;

  @override
  State<IncomingNotices> createState() => _IncomingNoticesState();
}

class _IncomingNoticesState extends State<IncomingNotices> with WidgetsBindingObserver {
  StreamSubscription<AuthUiState>? _authSubscription;
  RealtimeChannel? _channel;
  String? _subscribedUser;
  int _generation = 0;
  final Set<String> _seenMessages = <String>{};
  Timer? _dismissTimer;
  _BannerData? _banner;

  bool get _foreground {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatPage.openChatId.addListener(_onChatOpened);
    _authSubscription = widget.auth.stream.listen((_) => _syncSubscription());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncSubscription();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncSubscription();
    } else {
      _unsubscribe();
      _hideBanner();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatPage.openChatId.removeListener(_onChatOpened);
    unawaited(_authSubscription?.cancel() ?? Future<void>.value());
    _unsubscribe();
    _dismissTimer?.cancel();
    super.dispose();
  }

  void _syncSubscription() {
    if (!mounted) return;
    final userId = widget.auth.state.userId;
    if (!_foreground || !widget.auth.state.isReady || userId == null) {
      _unsubscribe();
      _seenMessages.clear();
      _hideBanner();
      return;
    }
    if (_subscribedUser == userId && _channel != null) return;
    _unsubscribe();
    _seenMessages.clear();
    _subscribedUser = userId;
    final generation = _generation;
    // RLS on `messages` restricts inserts to chats the signed-in user belongs to.
    // This is a foreground-only INSERT listener: it intentionally does not replay
    // old rows after reconnect (the chat list's unread badge already covers those).
    _channel = widget.client
        .channel('incoming-notices:$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            if (generation == _generation) unawaited(_consider(payload.newRecord, userId, generation));
          },
        )
        .subscribe();
  }

  void _unsubscribe() {
    _generation++;
    final previous = _channel;
    _channel = null;
    _subscribedUser = null;
    if (previous != null) unawaited(previous.unsubscribe());
  }

  bool _stillListening(String userId, int generation, String chatId) =>
      mounted &&
      _foreground &&
      _generation == generation &&
      _subscribedUser == userId &&
      widget.auth.state.isReady &&
      widget.auth.state.userId == userId &&
      ChatPage.openChatId.value != chatId;

  Future<void> _consider(Map<String, dynamic> row, String userId, int generation) async {
    final id = row['id']?.toString();
    final chatId = row['chat_id']?.toString();
    if (id == null || chatId == null || id.isEmpty || chatId.isEmpty) return;
    if (!_stillListening(userId, generation, chatId)) return;
    if (row['deleted_at'] != null || row['kind'] == 'system' || row['sender_id'] == userId) return;
    if (!_seenMessages.add(id)) return; // a Realtime reconnect must not re-banner one row
    if (_seenMessages.length > 256) _seenMessages.remove(_seenMessages.first);

    try {
      // A summary can be stale for ~450 ms while ChatsBloc folds Realtime updates;
      // consult the participant row instead so mute/read/leave wins that race.
      final participant = await widget.client
          .from('chat_participants')
          .select('unread_count, muted_until, left_at')
          .eq('user_id', userId)
          .eq('chat_id', chatId)
          .maybeSingle();
      if (participant == null || participant['left_at'] != null || asInt(participant['unread_count']) <= 0) return;
      if (widget.chats.state.chats.any((chat) => chat.chatId == chatId && chat.isMuted)) return;
      final muteValue = participant['muted_until'];
      if (muteValue != null) {
        final mutedUntil = DateTime.tryParse('$muteValue');
        if (mutedUntil == null || mutedUntil.isAfter(DateTime.now())) return;
      }

      if (row['source'] == 'telegram') {
        // A synced Telegram chat already buzzed in the owner's own Telegram.
        // Suppress the local banner too, not just the offline Saved Messages send.
        final mapping = await widget.client
            .from('telegram_chats')
            .select('sync_direction')
            .eq('owner_user_id', userId)
            .eq('chat_id', chatId)
            .maybeSingle();
        if (mapping != null && (mapping['sync_direction'] == 'both' || mapping['sync_direction'] == 'from_telegram')) {
          return;
        }
      }

      // Fetch for every banner rather than caching: a second device may just
      // have switched off previews. A read failure is content-free, never a guess.
      bool withPreview = false;
      try {
        withPreview = (await widget.telegram.pushPreferences()).preview;
      } catch (_) {
        // Continue with the generic, privacy-safe banner.
      }
      if (!_stillListening(userId, generation, chatId)) return;

      final sender = (row['sender_name']?.toString() ?? '').replaceAll(RegExp(r'[\n\r]+'), ' ').trim();
      final title = withPreview && sender.isNotEmpty ? sender : 'MessengerX';
      final text = withPreview ? _preview(row) : 'New message';
      final previous = _banner;
      final count = previous?.chatId == chatId ? previous!.count + 1 : 1;
      _dismissTimer?.cancel();
      setState(() => _banner = _BannerData(chatId: chatId, title: title, text: text, count: count));
      _dismissTimer = Timer(const Duration(seconds: 5), _hideBanner);
    } catch (_) {
      // A refused RLS read or a broken Realtime connection cannot make a banner
      // override the user's mute/privacy settings. The unread badge still works.
    }
  }

  static String _preview(Map<String, dynamic> row) {
    final body = (row['body']?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.isNotEmpty) return body.length > 140 ? '${body.substring(0, 140)}…' : body;
    return switch (row['kind']) {
      'image' => 'Photo',
      'voice' => 'Voice message',
      _ => 'New message',
    };
  }

  void _onChatOpened() {
    if (ChatPage.openChatId.value == _banner?.chatId) _hideBanner();
  }

  void _hideBanner() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    if (_banner != null && mounted) setState(() => _banner = null);
  }

  @override
  Widget build(BuildContext context) {
    final banner = _banner;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        if (banner != null && _foreground)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      elevation: 7,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        // No chat deep-link is implied by this banner. Tapping
                        // dismisses it; the chat list's unread badge is the truth.
                        onTap: _hideBanner,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.chat_bubble_rounded, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(banner.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleSmall),
                                    Text(
                                      banner.count > 1 ? '${banner.text} · +${banner.count - 1} more' : banner.text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.close_rounded, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BannerData {
  const _BannerData({required this.chatId, required this.title, required this.text, required this.count});

  final String chatId;
  final String title;
  final String text;
  final int count;
}
