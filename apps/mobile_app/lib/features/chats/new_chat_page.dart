import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../auth/auth_bloc.dart';
import 'chats_bloc.dart';
import 'widgets.dart';

/// Start a direct chat by username.
///
/// There is no contact graph and no phone-number lookup in Massanger: a username is
/// the only handle, which keeps `directory` small enough to search without an
/// index that leaks who-knows-whom.
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

  @override
  void initState() {
    super.initState();
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

  void _onChanged(String value) {
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
      if (!mounted) return;
      setState(() {
        _results = results;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
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
                                : 'Nobody by that name is on Massanger yet.',
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
