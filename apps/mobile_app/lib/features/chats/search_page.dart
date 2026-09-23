import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../auth/auth_bloc.dart';

/// Full-text search across every message the user can see.
///
/// `search_messages` is the database's own tsquery path (the trigger-maintained
/// `search_tsv` plus its GIN index), so this screen has no ranking logic of its
/// own: whatever Postgres considers the best match is what the user gets, in every
/// chat they belong to.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.chatId});

  final String? chatId;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<MessageItem> _results = const <MessageItem>[];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    if (value.trim().length < 2) {
      setState(() => _results = const <MessageItem>[]);
      return;
    }
    setState(() => _busy = true);
    try {
      final uid = context.read<AuthBloc>().state.userId ?? '';
      final results = await context
          .read<ChatRepository>()
          .searchMessages(query: value, chatId: widget.chatId, currentUserId: uid);
      if (!mounted) return;
      setState(() {
        _results = results;
        _error = null;
      });
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
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 280), () => _search(value));
          },
          decoration: const InputDecoration(hintText: 'Search your messages'),
        ),
      ),
      body: SafeArea(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: InlineError(
                  message: _error!,
                  onRetry: () => _search(_controller.text),
                ),
              )
            : _results.isEmpty
                ? Center(
                    child: Text(
                      _busy ? 'Searching…' : 'Nothing found yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final message = _results[index];
                      return ListTile(
                        dense: true,
                        title: Text(message.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${message.senderName} · ${ChatFormatting.dayLabel(message.timestamp)} ${ChatFormatting.clock(message.timestamp)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        onTap: () => context.go(Routes.chat(message.chatId)),
                      );
                    },
                  ),
      ),
    );
  }
}
