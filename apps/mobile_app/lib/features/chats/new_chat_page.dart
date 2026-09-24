import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';
import '../auth/auth_bloc.dart';
import 'chats_bloc.dart';
import 'widgets.dart';

/// Start a MessengerX chat or ask the linked TDLib worker to resolve one
/// public Telegram @username. There is deliberately no phone-number lookup or
/// contact-list enumeration across accounts.
class NewChatPage extends StatefulWidget {
  const NewChatPage({super.key, this.preferredUsername});

  final String? preferredUsername;

  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<DirectoryEntry> _results = const <DirectoryEntry>[];
  bool _busy = false;
  String? _error;
  TelegramStatus? _telegram;
  String? _telegramStatusError;

  static final RegExp _publicUsername = RegExp(r'^@?[A-Za-z][A-Za-z0-9_]{4,31}$');

  String? get _telegramUsername {
    final name = _controller.text.trim();
    return _publicUsername.hasMatch(name) ? name.replaceFirst('@', '') : null;
  }

  bool get _canStartTelegram => _telegram?.isLinked == true && _telegram?.mirrorToApp == true &&
      (_telegram?.syncDirection == 'both' || _telegram?.syncDirection == 'to_telegram');

  @override
  void initState() {
    super.initState();
    unawaited(_loadTelegram());
    final preferred = widget.preferredUsername;
    if (preferred != null && preferred.isNotEmpty) {
      _controller.text = preferred;
      _search(preferred);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadTelegram() async {
    try {
      final state = await sl<TelegramRepository>().status();
      if (mounted) setState(() { _telegram = state; _telegramStatusError = null; });
    } catch (error) {
      if (mounted) setState(() => _telegramStatusError = AppException.wrap(error).message);
    }
  }

  void _onChanged(String value) {
    setState(() {
      _error = null;
      if (value.trim().length < 2) _results = const <DirectoryEntry>[];
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), () => _search(value));
  }

  Future<void> _search(String value) async {
    if (value.trim().length < 2) {
      setState(() => _results = const <DirectoryEntry>[]);
      return;
    }
    try {
      final results = await context.read<ChatRepository>().searchPeople(value);
      if (!mounted || _controller.text.trim() != value.trim()) return;
      setState(() {
        _results = results;
        _error = null;
      });
    } catch (error) {
      if (!mounted || _controller.text.trim() != value.trim()) return;
      setState(() => _error = AppException.wrap(error).message);
    }
  }

  Future<void> _open(DirectoryEntry entry) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final chatId = await context.read<ChatRepository>().createDirectChat(peerId: entry.id);
      if (!mounted) return;
      // The list has to know before we navigate, or the new chat appears only after
      // the user comes back.
      context.read<ChatsBloc>().add(const ChatsRefreshRequested());
      context.go(Routes.chat(chatId));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = AppException.wrap(error).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTelegram() async {
    final username = _telegramUsername;
    if (username == null || !_canStartTelegram) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final telegram = sl<TelegramRepository>();
      final receipt = await telegram.startPublicChat(username);
      final deadline = receipt.expiresAt ?? DateTime.now().add(const Duration(minutes: 3));
      while (mounted && DateTime.now().isBefore(deadline)) {
        final lookup = await telegram.publicChatRequestState(receipt.requestId);
        if (lookup.status == 'succeeded' && lookup.chatId != null) {
          if (!mounted) return;
          context.read<ChatsBloc>().add(const ChatsRefreshRequested());
          context.go(Routes.chat(lookup.chatId!));
          return;
        }
        if (lookup.finished) {
          throw AppException('telegram', lookup.error ?? 'Telegram could not open this chat.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      if (mounted) throw const AppException('timeout', 'Telegram lookup timed out. Try again.');
    } catch (error) {
      if (mounted) setState(() => _error = AppException.wrap(error).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final own = context.select<AuthBloc, String?>((auth) => auth.state.userId);
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                decoration: const InputDecoration(
                  hintText: 'Search a @username or a name',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            if (_telegramUsername != null) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: OutlinedButton.icon(
                  onPressed: _busy || !_canStartTelegram ? null : _openTelegram,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(_busy ? 'Looking up Telegram user…' : 'Start Telegram chat with @$_telegramUsername'),
                ),
              ),
              if (!_canStartTelegram)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _telegramStatusError ?? (_telegram?.isLinked == true
                              ? 'Enable mirroring and outbound sync in Telegram settings.'
                              : 'Connect your Telegram account to chat with people there.'),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.push(_telegram?.isLinked == true
                            ? Routes.telegram : Routes.telegramLink),
                        child: Text(_telegram?.isLinked == true ? 'Settings' : 'Connect'),
                      ),
                    ],
                  ),
                ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: InlineError(message: _error!),
              ),
            Expanded(
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _controller.text.trim().length < 2
                                ? 'Type at least two characters.'
                                : 'Nobody by that name is on MessengerX yet. For Telegram, enter a public @username above.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _results.length,
                          separatorBuilder: (context, index) => const Divider(indent: 72, height: 1),
                          itemBuilder: (context, index) {
                            final entry = _results[index];
                            final isSelf = entry.id == own;
                            return ListTile(
                              enabled: !isSelf,
                              leading: PersonAvatar(
                                name: entry.displayName,
                                path: entry.avatar,
                                isOnline: entry.isOnline,
                              ),
                              title: Text(entry.displayName),
                              subtitle: Text(
                                isSelf ? 'That is you' : '@${entry.username}',
                                style: theme.textTheme.bodySmall,
                              ),
                              trailing: isSelf ? null : const Icon(Icons.chevron_right_rounded),
                              onTap: isSelf ? null : () => _open(entry),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
