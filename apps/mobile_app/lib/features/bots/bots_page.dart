import 'dart:async';

import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/bot_repository.dart';
import '../../data/chat_repository.dart';
import '../../data/models.dart';
import '../chats/widgets.dart';

/// The bot platform, from the owner's side.
///
/// Three ways in, and they are the whole Telegram model: talk to @BotFather to
/// create a bot, open one of yours to configure it, or install somebody else's
/// into a group. Creating a bot is free — the *hosting* is the trick, and that
/// is why the BotFather flow ends in a token plus a `bot-api` endpoint on an
/// edge function the deployment already runs.
class BotsPage extends StatefulWidget {
  const BotsPage({super.key});

  @override
  State<BotsPage> createState() => _BotsPageState();
}

class _BotsPageState extends State<BotsPage> {
  List<BotSummary> _mine = const <BotSummary>[];
  List<BotSummary> _directory = const <BotSummary>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bots = sl<BotRepository>();
      final mine = await bots.mine();
      final directory = await bots.directory();
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _directory = directory.where((bot) => !bot.isBotFather).toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'Bots could not be loaded.';
      });
    }
  }

  Future<void> _openBotFather() async {
    try {
      final chatId = await sl<BotRepository>().botFatherChat();
      if (mounted) context.push(Routes.chat(chatId));
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _create() async {
    final draft = await showDialog<({String username, String displayName, String? about})>(
      context: context,
      builder: (dialogContext) => const _CreateBotDialog(),
    );
    if (draft == null) return;
    try {
      final created = await sl<BotRepository>().create(
        username: draft.username,
        displayName: draft.displayName,
        about: draft.about,
      );
      if (!mounted) return;
      await _showToken(created.username, created.token, firstTime: true);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _showToken(String username, String token, {bool firstTime = false}) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(firstTime ? '@$username is live' : 'New token for @$username'),
            if (firstTime)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Message the bot in the app, or point your own server at the bot-api endpoint with this token. '
                  'Nobody — including us — can show it again after you close this sheet.',
                  style: TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ),
            const SizedBox(height: 14),
            SelectableText(
              token,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: token));
                      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                      _toast('Token copied.');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy token'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _install(BotSummary bot) async {
    List<ChatSummary> groups;
    try {
      final chats = await sl<ChatRepository>().summaries();
      groups = chats.where((chat) => chat.kind == ChatKind.group).toList(growable: false);
    } catch (error) {
      _toast('Your groups could not be loaded.');
      return;
    }
    if (!mounted) return;
    if (groups.isEmpty) {
      _toast('Create a group first — a bot needs a place to live.');
      return;
    }
    final chatId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Add @${bot.username} to a group', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final group in groups)
              ListTile(
                leading: PersonAvatar(name: group.title ?? 'Group', path: group.avatarPath),
                title: Text(group.title ?? 'Group'),
                onTap: () => Navigator.of(sheetContext).pop(group.chatId),
              ),
          ],
        ),
      ),
    );
    if (chatId == null) return;
    try {
      await sl<BotRepository>().install(bot.id, chatId);
      _toast('@${bot.username} joined the group. Tap a group and use /help to see its commands.');
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Bots')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New bot'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? InlineError(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                    children: <Widget>[
                      Card(
                        elevation: 0,
                        color: scheme.surfaceContainerHighest,
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.smart_toy_rounded)),
                          title: const Text('@BotFather'),
                          subtitle: const Text('Create a bot, set its commands, rotate its token.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: _openBotFather,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const _BotsHeader('Your bots'),
                      if (_mine.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No bots yet. Say /newbot to @BotFather and you will have one in a minute.',
                            style: TextStyle(fontSize: 13, height: 1.4),
                          ),
                        )
                      else
                        for (final bot in _mine)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: PersonAvatar(name: bot.displayName, path: bot.avatarPath, size: 42),
                            title: Text(bot.displayName),
                            subtitle: Text(
                              '@${bot.username} · ${bot.installCount} install${bot.installCount == 1 ? '' : 's'}'
                              '${bot.isBotFather ? ' · the master bot' : ''}',
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => context.push(Routes.bot(bot.id)),
                          ),
                      const SizedBox(height: 18),
                      const _BotsHeader('Public bots'),
                      if (_directory.isEmpty)
                        const Text('No public bots have been published yet.', style: TextStyle(fontSize: 13))
                      else
                        for (final bot in _directory)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: PersonAvatar(name: bot.displayName, path: bot.avatarPath, size: 42),
                            title: Row(
                              children: <Widget>[
                                Flexible(child: Text(bot.displayName, overflow: TextOverflow.ellipsis)),
                                if (bot.isVerified) ...<Widget>[
                                  const SizedBox(width: 4),
                                  const VerifiedBadge(size: 13),
                                ],
                              ],
                            ),
                            subtitle: Text(bot.about ?? '@${bot.username}'),
                            trailing: FilledButton.tonal(
                              onPressed: () => _install(bot),
                              child: const Text('Add'),
                            ),
                          ),
                    ],
                  ),
                ),
    );
  }
}

class _BotsHeader extends StatelessWidget {
  const _BotsHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

class _CreateBotDialog extends StatefulWidget {
  const _CreateBotDialog();

  @override
  State<_CreateBotDialog> createState() => _CreateBotDialogState();
}

class _CreateBotDialogState extends State<_CreateBotDialog> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _display = TextEditingController();
  final TextEditingController _about = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _display.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create a bot'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _username,
            autofocus: true,
            maxLength: 32,
            decoration: const InputDecoration(labelText: 'Handle', hintText: 'weather_bot', counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _display,
            maxLength: 48,
            decoration: const InputDecoration(labelText: 'Display name', counterText: ''),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _about,
            maxLines: 2,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'What does it do?', counterText: ''),
          ),
          const SizedBox(height: 8),
          const Text(
            'Bots are free. They run on the platform: commands, moderation and scheduled posts need no server of yours.',
            style: TextStyle(fontSize: 12, height: 1.4),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _username.text.trim().length < 3
              ? null
              : () => Navigator.of(context).pop((
                    username: _username.text.trim().toLowerCase(),
                    displayName: _display.text.trim().isEmpty ? _username.text.trim() : _display.text.trim(),
                    about: _about.text.trim().isEmpty ? null : _about.text.trim(),
                  )),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// One bot's control room: identity, commands, webhook, moderation rules,
/// scheduled posts and the token.
class BotBuilderPage extends StatefulWidget {
  const BotBuilderPage({super.key, this.botId});

  final String? botId;

  @override
  State<BotBuilderPage> createState() => _BotBuilderPageState();
}

class _BotBuilderPageState extends State<BotBuilderPage> {
  BotSummary? _bot;
  List<BotCommand> _commands = const <BotCommand>[];
  List<Map<String, dynamic>> _rules = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _broadcasts = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  /// The builtins the platform runs itself. A bot owner picks one of these and
  /// the automation happens server-side, with no endpoint to keep alive.
  static const List<({String name, String description})> _builtins = <({String name, String description})>[
    (name: 'mute', description: 'Silence a member for a while'),
    (name: 'unmute', description: 'Restore a member’s voice'),
    (name: 'kick', description: 'Remove a member'),
    (name: 'ban', description: 'Ban a member from the group'),
    (name: 'warn', description: 'Record a warning against a member'),
    (name: 'purge', description: 'Delete the last N messages'),
    (name: 'pin', description: 'Pin a message'),
    (name: 'rules', description: 'Post the group rules'),
    (name: 'slowmode', description: 'Set the channel slow mode'),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final botId = widget.botId;
    if (botId == null) {
      setState(() {
        _loading = false;
        _error = 'Open a bot from the list to configure it.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bot = sl<BotRepository>();
      final mine = await bot.mine();
      final commands = await bot.commands(botId);
      final rules = await bot.rules(botId);
      final broadcasts = await bot.broadcasts(botId);
      if (!mounted) return;
      setState(() {
        _bot = mine.where((candidate) => candidate.id == botId).firstOrNull;
        _commands = commands;
        _rules = rules;
        _broadcasts = broadcasts;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'This bot could not be loaded.';
      });
    }
  }

  Future<void> _editIdentity() async {
    final bot = _bot;
    if (bot == null) return;
    final display = TextEditingController(text: bot.displayName);
    final about = TextEditingController(text: bot.about ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Bot profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(controller: display, decoration: const InputDecoration(labelText: 'Display name')),
            const SizedBox(height: 10),
            TextField(controller: about, maxLines: 3, decoration: const InputDecoration(labelText: 'About')),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      try {
        await sl<BotRepository>().update(
          bot.id,
          displayName: display.text.trim(),
          about: about.text.trim(),
        );
        await _load();
      } on AppException catch (error) {
        _toast(error.message);
      }
    }
    display.dispose();
    about.dispose();
  }

  Future<void> _addCommand() async {
    final bot = _bot;
    if (bot == null) return;
    final draft = await showModalBottomSheet<({String name, String description, String? builtin})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Add a command', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final builtin in _builtins)
              ListTile(
                leading: const Icon(Icons.bolt_rounded),
                title: Text('/${builtin.name}'),
                subtitle: Text(builtin.description),
                onTap: () => Navigator.of(sheetContext).pop(
                  (name: builtin.name, description: builtin.description, builtin: builtin.name),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.webhook_rounded),
              title: const Text('Custom command'),
              subtitle: const Text('Handled by your own endpoint through the webhook.'),
              onTap: () => Navigator.of(sheetContext).pop(
                (name: '', description: '', builtin: null),
              ),
            ),
          ],
        ),
      ),
    );
    if (draft == null) return;
    var name = draft.name;
    var description = draft.description;
    if (draft.builtin == null) {
      final nameController = TextEditingController();
      final descriptionController = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Custom command'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: nameController,
                maxLength: 32,
                decoration: const InputDecoration(labelText: 'Command', hintText: 'weather', counterText: ''),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descriptionController,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Description', counterText: ''),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Add')),
          ],
        ),
      );
      if (confirmed != true) {
        nameController.dispose();
        descriptionController.dispose();
        return;
      }
      name = nameController.text.trim().toLowerCase();
      description = descriptionController.text.trim();
      nameController.dispose();
      descriptionController.dispose();
      if (name.isEmpty) return;
    }
    try {
      final next = <Map<String, Object?>>[
        for (final command in _commands)
          <String, Object?>{
            'command': command.command,
            'description': command.description,
            if (command.builtin != null) 'builtin': command.builtin,
          },
        <String, Object?>{
          'command': name,
          'description': description,
          if (draft.builtin != null) 'builtin': draft.builtin,
        },
      ];
      // The editor sends the whole set: the RPC replaces what is there, which is
      // the only way to express a deletion without a second endpoint.
      await sl<BotRepository>().setCommands(bot.id, next);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _removeCommand(BotCommand command) async {
    final bot = _bot;
    if (bot == null) return;
    try {
      final next = <Map<String, Object?>>[
        for (final existing in _commands)
          if (existing.command != command.command)
            <String, Object?>{
              'command': existing.command,
              'description': existing.description,
              if (existing.builtin != null) 'builtin': existing.builtin,
            },
      ];
      await sl<BotRepository>().setCommands(bot.id, next);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _setWebhook() async {
    final bot = _bot;
    if (bot == null) return;
    final controller = TextEditingController(text: bot.webhookUrl ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Webhook'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'An HTTPS endpoint that receives updates. Every payload is signed with this install’s secret, so your '
              'server can trust it without calling back here.',
              style: TextStyle(fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'https://example.com/hook', hintText: 'leave empty to remove'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Save')),
        ],
      ),
    );
    final url = controller.text.trim();
    controller.dispose();
    if (saved != true) return;
    try {
      await sl<BotRepository>().setWebhook(bot.id, url.isEmpty ? null : url);
      _toast(url.isEmpty ? 'Webhook removed.' : 'Webhook saved.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _addRule() async {
    final bot = _bot;
    if (bot == null) return;
    final keyword = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Moderation rule'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Messages containing this word are handled automatically: the platform deletes them, warns the author, '
              'or mutes them, with no server of yours in the loop.',
              style: TextStyle(fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(controller: keyword, decoration: const InputDecoration(labelText: 'Word or phrase')),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Add')),
        ],
      ),
    );
    final word = keyword.text.trim();
    keyword.dispose();
    if (confirmed != true || word.isEmpty) return;
    try {
      await sl<BotRepository>().saveRule(
        bot.id,
        kind: 'keyword',
        config: <String, dynamic>{'keywords': <String>[word]},
        action: 'delete',
      );
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _schedule() async {
    final bot = _bot;
    if (bot == null) return;
    final body = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Schedule a broadcast'),
        content: TextField(
          controller: body,
          maxLines: 4,
          maxLength: 1000,
          decoration: const InputDecoration(labelText: 'Message', counterText: ''),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Schedule')),
        ],
      ),
    );
    final text = body.text.trim();
    body.dispose();
    if (saved != true || text.isEmpty) return;
    try {
      await sl<BotRepository>().scheduleBroadcast(
        bot.id,
        body: text,
        sendAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      _toast('Broadcast scheduled for five minutes from now.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _rotate() async {
    final bot = _bot;
    if (bot == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Issue a new token?'),
        content: const Text('The old token stops working immediately. Any server using it will need the new one.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Rotate')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final token = await sl<BotRepository>().rotateToken(bot.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('New token for @${bot.username}'),
              const SizedBox(height: 12),
              SelectableText(token, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  _toast('Token copied.');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy token'),
              ),
            ],
          ),
        ),
      );
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _delete() async {
    final bot = _bot;
    if (bot == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete @${bot.username}?'),
        content: const Text('Its commands stop working and it leaves every group. This cannot be undone.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await sl<BotRepository>().delete(bot.id);
      if (mounted) context.pop();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bot = _bot;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(bot == null ? 'Bot' : '@${bot.username}'),
        actions: <Widget>[
          if (bot != null)
            IconButton(
              tooltip: 'Message the bot',
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              onPressed: () async {
                try {
                  final chatId = await sl<ChatRepository>().createDirectChat(peerId: bot.profileId);
                  if (mounted) context.push(Routes.chat(chatId));
                } on AppException catch (error) {
                  _toast(error.message);
                }
              },
            ),
          if (bot != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'rotate':
                    unawaited(_rotate());
                  case 'delete':
                    unawaited(_delete());
                }
              },
              itemBuilder: (context) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'rotate', child: Text('Issue a new token')),
                PopupMenuItem<String>(value: 'delete', child: Text('Delete bot')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : bot == null
              ? InlineError(message: _error ?? 'This bot is not yours to edit.', onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        PersonAvatar(name: bot.displayName, path: bot.avatarPath, size: 54),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(bot.displayName, style: Theme.of(context).textTheme.titleMedium),
                              Text(
                                '@${bot.username} · ${bot.installCount} install${bot.installCount == 1 ? '' : 's'}',
                                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(onPressed: _editIdentity, icon: const Icon(Icons.edit_rounded, size: 18)),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _BotSection(
                      title: 'Commands',
                      subtitle: 'A builtin runs on the platform. A custom command is delivered to your webhook.',
                      action: TextButton.icon(
                        onPressed: _addCommand,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add'),
                      ),
                    ),
                    if (_commands.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text('No commands yet. /help is a good first one.', style: TextStyle(fontSize: 13)),
                      )
                    else
                      for (final command in _commands)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            command.builtin == null ? Icons.webhook_rounded : Icons.bolt_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                          title: Text(command.slash),
                          subtitle: Text(command.description),
                          trailing: IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => _removeCommand(command),
                          ),
                        ),
                    const SizedBox(height: 18),
                    _BotSection(
                      title: 'Webhook',
                      subtitle: bot.webhookUrl == null ? 'Not set — custom commands have nowhere to go.' : bot.webhookUrl!,
                      action: TextButton(onPressed: _setWebhook, child: Text(bot.webhookUrl == null ? 'Set' : 'Change')),
                    ),
                    const SizedBox(height: 18),
                    _BotSection(
                      title: 'Moderation rules',
                      subtitle: 'Automatic handling for keywords your group does not tolerate.',
                      action: TextButton.icon(
                        onPressed: _addRule,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add'),
                      ),
                    ),
                    if (_rules.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text('No rules. The bot only reacts to commands.', style: TextStyle(fontSize: 13)),
                      )
                    else
                      for (final rule in _rules)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.gavel_rounded),
                          title: Text('${rule['kind'] ?? 'rule'} → ${rule['action'] ?? 'delete'}'),
                          subtitle: Text(
                            rule['config'] is Map
                                ? '${(rule['config'] as Map)['keywords'] ?? rule['config']}'
                                : '${rule['config'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    const SizedBox(height: 18),
                    _BotSection(
                      title: 'Scheduled broadcasts',
                      subtitle: 'Posts the platform delivers for you, with no server to keep awake.',
                      action: TextButton.icon(
                        onPressed: _schedule,
                        icon: const Icon(Icons.schedule_send_rounded, size: 18),
                        label: const Text('Schedule'),
                      ),
                    ),
                    if (_broadcasts.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text('Nothing scheduled.', style: TextStyle(fontSize: 13)),
                      )
                    else
                      for (final broadcast in _broadcasts)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.campaign_outlined),
                          title: Text(
                            '${broadcast['body'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${broadcast['status'] ?? 'pending'} · ${broadcast['send_at'] ?? ''}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () async {
                              final id = broadcast['id'];
                              if (id == null) return;
                              try {
                                await sl<BotRepository>().cancelBroadcast('$id');
                                await _load();
                              } on AppException catch (error) {
                                _toast(error.message);
                              }
                            },
                          ),
                        ),
                  ],
                ),
    );
  }
}

class _BotSection extends StatelessWidget {
  const _BotSection({required this.title, required this.subtitle, this.action});

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.35)),
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}
