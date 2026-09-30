import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/discord_markdown.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../../data/shorts_repository.dart';
import '../auth/auth_bloc.dart';
import '../shorts/video_player_screen.dart';
import 'widgets.dart';

/// Universal Autocomplete Search:
/// Searches #channels, @users, tags, videos, and messages.
class UniversalSearchPage extends StatefulWidget {
  const UniversalSearchPage({super.key});

  @override
  State<UniversalSearchPage> createState() => _UniversalSearchPageState();
}

class _UniversalSearchPageState extends State<UniversalSearchPage> with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  late TabController _tabController;
  Timer? _debounce;

  List<DirectoryEntry> _users = const <DirectoryEntry>[];
  List<ShortVideo> _videos = const <ShortVideo>[];
  List<MessageItem> _messages = const <MessageItem>[];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _users = const <DirectoryEntry>[];
        _videos = const <ShortVideo>[];
        _messages = const <MessageItem>[];
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 280), () => _executeSearch(query.trim()));
  }

  Future<void> _executeSearch(String query) async {
    setState(() => _busy = true);
    try {
      final uid = context.read<AuthBloc>().state.userId ?? '';
      final chatRepo = sl<ChatRepository>();
      final shortsRepo = sl<ShortsRepository>();

      // Parallel fetch across users, videos, and messages
      final futures = await Future.wait([
        chatRepo.searchPeople(query),
        shortsRepo.page(limit: 20),
        chatRepo.searchMessages(query: query, currentUserId: uid),
      ]);

      if (!mounted || _controller.text.trim() != query) return;

      final allVideos = futures[1] as List<ShortVideo>;
      final matchingVideos = allVideos.where((v) {
        final title = (v.title ?? '').toLowerCase();
        final desc = (v.caption ?? v.description ?? '').toLowerCase();
        final q = query.toLowerCase();
        return title.contains(q) || desc.contains(q);
      }).toList();

      setState(() {
        _users = futures[0] as List<DirectoryEntry>;
        _videos = matchingVideos;
        _messages = futures[2] as List<MessageItem>;
        _busy = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = AppException.wrap(e).message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Search #channels, @users, videos...',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: scheme.primary,
          tabs: <Widget>[
            Tab(text: 'Top (${_users.length + _videos.length + _messages.length})'),
            Tab(text: 'Videos (${_videos.length})'),
            Tab(text: 'Users (${_users.length})'),
            Tab(text: 'Messages (${_messages.length})'),
          ],
        ),
      ),
      body: SafeArea(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: InlineError(message: _error!, onRetry: () => _executeSearch(_controller.text.trim())),
                  )
                : _controller.text.trim().length < 2
                    ? Center(
                        child: Text(
                          'Type @user, #channel or video keywords',
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : TabBarView(
                        controller: _tabController,
                        children: <Widget>[
                          // Top Mixed Results
                          _buildTopList(context),
                          // Videos Only
                          _buildVideoList(context),
                          // Users Only
                          _buildUserList(context),
                          // Messages Only
                          _buildMessageList(context),
                        ],
                      ),
      ),
    );
  }

  Widget _buildTopList(BuildContext context) {
    if (_videos.isEmpty && _users.isEmpty && _messages.isEmpty) {
      return const Center(child: Text('No matching results.'));
    }
    return ListView(
      children: <Widget>[
        if (_videos.isNotEmpty) ...<Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Videos & Shorts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
          ),
          ..._videos.take(3).map((v) => _videoTile(context, v)),
        ],
        if (_users.isNotEmpty) ...<Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Users & Creators', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
          ),
          ..._users.take(4).map((u) => _userTile(context, u)),
        ],
        if (_messages.isNotEmpty) ...<Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Messages', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
          ),
          ..._messages.take(4).map((m) => _messageTile(context, m)),
        ],
      ],
    );
  }

  Widget _buildVideoList(BuildContext context) {
    if (_videos.isEmpty) return const Center(child: Text('No videos found.'));
    return ListView.separated(
      itemCount: _videos.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _videoTile(context, _videos[index]),
    );
  }

  Widget _buildUserList(BuildContext context) {
    if (_users.isEmpty) return const Center(child: Text('No users found.'));
    return ListView.separated(
      itemCount: _users.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _userTile(context, _users[index]),
    );
  }

  Widget _buildMessageList(BuildContext context) {
    if (_messages.isEmpty) return const Center(child: Text('No messages found.'));
    return ListView.separated(
      itemCount: _messages.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _messageTile(context, _messages[index]),
    );
  }

  Widget _videoTile(BuildContext context, ShortVideo video) {
    return ListTile(
      leading: Container(
        width: 48,
        height: 36,
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
      ),
      title: Text(video.title ?? video.caption ?? 'Untitled', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${video.authorName ?? '@creator'} • ${ChatFormatting.duration(video.duration)}', style: const TextStyle(fontSize: 12)),
      trailing: video.isLong
          ? const Chip(label: Text('16:9 Video', style: TextStyle(fontSize: 10)))
          : const Chip(label: Text('Short', style: TextStyle(fontSize: 10))),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoPlayerScreen(video: video)));
      },
    );
  }

  Widget _userTile(BuildContext context, DirectoryEntry user) {
    return ListTile(
      leading: PersonAvatar(name: user.displayName, path: user.avatar, isOnline: user.isOnline),
      title: Row(
        children: <Widget>[
          Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (user.roleBadge != null) ...<Widget>[
            const SizedBox(width: 6),
            DiscordRoleBadge(badge: user.roleBadge!, colorHex: user.roleColor, discriminator: user.discriminator, compact: true),
          ],
        ],
      ),
      subtitle: Text('@${user.username}${user.discriminator != null ? '#${user.discriminator}' : ''}'),
      onTap: () async {
        final chatId = await sl<ChatRepository>().createDirectChat(peerId: user.id);
        if (context.mounted) context.push(Routes.chat(chatId));
      },
    );
  }

  Widget _messageTile(BuildContext context, MessageItem message) {
    return ListTile(
      leading: const Icon(Icons.chat_bubble_outline_rounded),
      title: Text(message.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${message.senderName} • ${ChatFormatting.dayLabel(message.timestamp)}'),
      onTap: () => context.push(Routes.chat(message.chatId)),
    );
  }
}
