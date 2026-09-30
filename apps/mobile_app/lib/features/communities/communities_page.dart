import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/community_repository.dart';
import '../../data/social_repository.dart';
import '../chats/widgets.dart';

/// The Discord side of the product: servers you own or joined, and a directory
/// to find new ones.
///
/// A community is a real server — categories, channel permissions, roles and
/// voice rooms — so this list is deliberately boring: name, size, and a join
/// button that can only ever *ask* the server to add you.
class CommunitiesPage extends StatefulWidget {
  const CommunitiesPage({super.key});

  @override
  State<CommunitiesPage> createState() => _CommunitiesPageState();
}

class _CommunitiesPageState extends State<CommunitiesPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  List<CommunitySummary> _mine = const <CommunitySummary>[];
  List<CommunitySummary> _directory = const <CommunitySummary>[];
  List<ChannelSummary> _channels = const <ChannelSummary>[];
  bool _loading = true;
  bool _searching = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final communities = sl<CommunityRepository>();
      final mine = await communities.mine();
      final directory = await communities.directory();
      final channels = await communities.channelDirectory();
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _directory = directory;
        _channels = channels;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'Communities could not be loaded.';
      });
    }
  }

  Future<void> _search(String query) async {
    setState(() {
      _query = query;
      _searching = true;
    });
    try {
      final community = sl<CommunityRepository>();
      final trimmed = query.trim();
      final results = trimmed.isEmpty ? await community.directory() : await community.directory(query: trimmed);
      final channels = trimmed.isEmpty ? await community.channelDirectory() : await community.channelDirectory(query: trimmed);
      if (!mounted || _query != query) return;
      setState(() {
        _directory = results;
        _channels = channels;
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _join(CommunitySummary community) async {
    try {
      await sl<CommunityRepository>().join(slug: community.slug);
      if (!mounted) return;
      _toast('Joined ${community.name}.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _joinChannel(ChannelSummary channel) async {
    try {
      final chatId = await sl<CommunityRepository>().joinChannel(chatId: channel.chatId);
      if (!mounted) return;
      context.push(Routes.chat(chatId));
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _create() async {
    final draft = await showDialog<_CommunityDraft>(
      context: context,
      builder: (dialogContext) => const _CreateCommunityDialog(),
    );
    if (draft == null) return;
    try {
      final id = await sl<CommunityRepository>().create(
        name: draft.name,
        slug: draft.slug,
        description: draft.description,
        isPublic: draft.isPublic,
      );
      if (!mounted) return;
      _toast('${draft.name} is live. Add a channel to get started.');
      context.push(Routes.community(id));
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Communities'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const <Widget>[
            Tab(text: 'Mine'),
            Tab(text: 'Discover'),
            Tab(text: 'Channels'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New community'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? InlineError(message: _error!, onRetry: _load)
              : TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    RefreshIndicator(
                      onRefresh: _load,
                      child: _mine.isEmpty
                          ? const EmptyState(
                              title: 'No communities yet',
                              message: 'Create one, or find a server in Discover and join it.',
                              icon: Icons.groups_outlined,
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 96),
                              itemCount: _mine.length,
                              itemBuilder: (context, index) {
                                final community = _mine[index];
                                return _CommunityTile(
                                  community: community,
                                  trailing: CommunityPermissions.has(
                                    community.myPermissions,
                                    CommunityPermissions.manageChannels,
                                  )
                                      ? const Icon(Icons.settings_rounded, size: 18)
                                      : null,
                                  onTap: () => context.push(Routes.community(community.id)),
                                );
                              },
                            ),
                    ),
                    Column(
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                          child: TextField(
                            decoration: const InputDecoration(
                              hintText: 'Search public communities',
                              prefixIcon: Icon(Icons.search_rounded),
                            ),
                            onChanged: (value) => unawaited(_search(value)),
                          ),
                        ),
                        if (_searching) const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: _directory.isEmpty
                              ? const EmptyState(
                                  title: 'Nothing public yet',
                                  message: 'Public communities show up here as soon as they are created.',
                                  icon: Icons.public_off_outlined,
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.only(bottom: 96),
                                  itemCount: _directory.length,
                                  itemBuilder: (context, index) {
                                    final community = _directory[index];
                                    return _CommunityTile(
                                      community: community,
                                      trailing: community.joined
                                          ? const Icon(Icons.check_rounded, size: 18)
                                          : FilledButton.tonal(
                                              onPressed: () => _join(community),
                                              child: const Text('Join'),
                                            ),
                                      onTap: () => community.joined
                                          ? context.push(Routes.community(community.id))
                                          : _join(community),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                    _channels.isEmpty
                        ? const EmptyState(
                            title: 'No public channels',
                            message: 'Broadcast channels (Telegram-style, one voice to many readers) appear here.',
                            icon: Icons.campaign_outlined,
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: _channels.length,
                            itemBuilder: (context, index) {
                              final channel = _channels[index];
                              return ListTile(
                                leading: PersonAvatar(name: channel.title, path: channel.avatarPath),
                                title: Text(channel.title),
                                subtitle: Text(
                                  '${channel.subscriberCount} subscribers'
                                  '${channel.handle == null ? '' : ' · ${channel.at}'}',
                                ),
                                trailing: channel.joined
                                    ? const Icon(Icons.check_rounded, size: 18)
                                    : FilledButton.tonal(
                                        onPressed: () => _joinChannel(channel),
                                        child: const Text('Join'),
                                      ),
                                onTap: () => channel.joined ? _joinChannel(channel) : null,
                              );
                            },
                          ),
                  ],
                ),
    );
  }
}

class _CommunityTile extends StatelessWidget {
  const _CommunityTile({required this.community, required this.onTap, this.trailing});

  final CommunitySummary community;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: community.iconKey == null
          ? CircleAvatar(
              backgroundColor: Brand.seed.withOpacity(0.14),
              child: Text(
                community.name.isEmpty ? '?' : community.name.characters.first.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.seed),
              ),
            )
          : PersonAvatar(name: community.name, path: community.iconKey, size: 42),
      title: Text(community.name),
      subtitle: Text(
        '${community.memberCount} members'
        '${community.onlineCount > 0 ? ' · ${community.onlineCount} online' : ''}'
        '${community.isPublic ? '' : ' · private'}',
      ),
      trailing: trailing,
      onTap: onTap,
      selected: false,
      textColor: scheme.onSurface,
    );
  }
}

class _CommunityDraft {
  const _CommunityDraft({required this.name, required this.slug, this.description, required this.isPublic});

  final String name;
  final String slug;
  final String? description;
  final bool isPublic;
}

class _CreateCommunityDialog extends StatefulWidget {
  const _CreateCommunityDialog();

  @override
  State<_CreateCommunityDialog> createState() => _CreateCommunityDialogState();
}

class _CreateCommunityDialogState extends State<_CreateCommunityDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _slug = TextEditingController();
  final TextEditingController _description = TextEditingController();
  bool _isPublic = true;
  bool _slugEdited = false;

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _description.dispose();
    super.dispose();
  }

  /// Slugs are 3–48 characters of `[a-z0-9-]` in the database, so the field is
  /// filled from the name and then left alone if the person edits it.
  String _slugify(String value) {
    final slug = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.length > 48 ? slug.substring(0, 48) : slug;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New community'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 48,
            decoration: const InputDecoration(labelText: 'Name', counterText: ''),
            onChanged: (value) {
              if (_slugEdited) return;
              _slug.text = _slugify(value);
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _slug,
            decoration: const InputDecoration(labelText: 'Slug', hintText: 'my-community'),
            onChanged: (_) => _slugEdited = true,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            maxLines: 2,
            maxLength: 280,
            decoration: const InputDecoration(labelText: 'Description', counterText: ''),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Public'),
            subtitle: const Text('Anyone can find and join it.'),
            value: _isPublic,
            onChanged: (value) => setState(() => _isPublic = value),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final slug = _slug.text.trim();
            if (name.isEmpty || slug.length < 3) return;
            Navigator.of(context).pop(
              _CommunityDraft(
                name: name,
                slug: slug,
                description: _description.text.trim().isEmpty ? null : _description.text.trim(),
                isPublic: _isPublic,
              ),
            );
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// One server, opened.
///
/// The screen is a Discord client's three panes flattened onto tabs, which is
/// what fits a phone: channels (with the voice rooms underneath), members (with
/// moderation), and roles. Every editing control is gated on the permission
/// mask the server returned, and the mask is only ever a *hint* — the RPCs
/// enforce the same bits again.
class CommunityPage extends StatefulWidget {
  const CommunityPage({super.key, required this.communityId});

  final String communityId;

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  CommunityOverview? _overview;
  bool _loading = true;
  String? _error;
  String? _voiceChannelId;
  final String _sessionId = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    final channelId = _voiceChannelId;
    if (channelId != null) {
      unawaited(sl<CommunityRepository>().voiceLeave(channelId).catchError((Object _) {}));
    }
    _tabs.dispose();
    super.dispose();
  }

  int get _permissions => _overview?.myPermissions ?? 0;

  bool _can(int permission) => CommunityPermissions.has(_permissions, permission);

  Future<void> _load() async {
    try {
      final overview = await sl<CommunityRepository>().overview(widget.communityId);
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AppException ? error.message : 'This community could not be loaded.';
      });
    }
  }

  Future<void> _createChannel({String kind = 'text', String? categoryId}) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(kind == 'voice' ? 'New voice room' : 'New channel'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(labelText: 'Name', counterText: ''),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await sl<CommunityRepository>().createChannel(
        widget.communityId,
        name: name,
        kind: kind,
        categoryId: categoryId,
      );
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _channelSheet(CommunityChannel channel) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rename or re-topic'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _editChannel(channel);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Slow mode'),
              subtitle: Text(channel.slowmodeSeconds == 0 ? 'Off' : '${channel.slowmodeSeconds}s between messages'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _setSlowmode(channel);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(sheetContext).colorScheme.error),
              title: Text('Delete channel', style: TextStyle(color: Theme.of(sheetContext).colorScheme.error)),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _deleteChannel(channel);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editChannel(CommunityChannel channel) async {
    final nameController = TextEditingController(text: channel.name);
    final topicController = TextEditingController(text: channel.topic ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Channel settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 10),
            TextField(controller: topicController, decoration: const InputDecoration(labelText: 'Topic')),
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
        await sl<CommunityRepository>().updateChannel(
          channel.id,
          name: nameController.text.trim(),
          topic: topicController.text.trim().isEmpty ? null : topicController.text.trim(),
        );
        await _load();
      } on AppException catch (error) {
        _toast(error.message);
      }
    }
    nameController.dispose();
    topicController.dispose();
  }

  Future<void> _setSlowmode(CommunityChannel channel) async {
    final seconds = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final value in const <int>[0, 5, 15, 30, 60, 300])
              ListTile(
                title: Text(value == 0 ? 'Off' : '$value seconds'),
                onTap: () => Navigator.of(sheetContext).pop(value),
              ),
          ],
        ),
      ),
    );
    if (seconds == null) return;
    try {
      await sl<CommunityRepository>().updateChannel(channel.id, slowmodeSeconds: seconds);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _deleteChannel(CommunityChannel channel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete #${channel.name}?'),
        content: const Text('Messages in this channel stop being visible. This cannot be undone.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await sl<CommunityRepository>().deleteChannel(channel.id);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _toggleVoice(CommunityChannel channel) async {
    final target = channel.chatId ?? channel.id;
    try {
      final community = sl<CommunityRepository>();
      if (_voiceChannelId == target) {
        await community.voiceLeave(target);
        if (mounted) setState(() => _voiceChannelId = null);
      } else {
        if (_voiceChannelId != null) await community.voiceLeave(_voiceChannelId!);
        await community.voiceJoin(target, _sessionId);
        if (mounted) setState(() => _voiceChannelId = target);
      }
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _memberSheet(CommunityMember member) async {
    final roles = _overview?.roles ?? const <CommunityRole>[];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: PersonAvatar(name: member.displayName ?? member.username, path: member.avatarPath, size: 44),
              title: Text(member.nickname?.isNotEmpty == true ? member.nickname! : (member.displayName ?? member.username)),
              subtitle: Text(handleOf(member.username)),
            ),
            const Divider(),
            if (_can(CommunityPermissions.moderateMembers) || _can(CommunityPermissions.administrator)) ...<Widget>[
              ListTile(
                leading: const Icon(Icons.volume_off_rounded),
                title: const Text('Mute for 10 minutes'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_moderate(member, 'mute', minutes: 10));
                },
              ),
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded),
                title: const Text('Warn'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_moderate(member, 'warn'));
                },
              ),
            ],
            if (_can(CommunityPermissions.kickMembers)) ...<Widget>[
              ListTile(
                leading: const Icon(Icons.logout_rounded),
                title: const Text('Kick'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_moderate(member, 'kick'));
                },
              ),
            ],
            if (_can(CommunityPermissions.banMembers))
              ListTile(
                leading: Icon(Icons.block_rounded, color: Theme.of(sheetContext).colorScheme.error),
                title: Text('Ban', style: TextStyle(color: Theme.of(sheetContext).colorScheme.error)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_moderate(member, 'ban'));
                },
              ),
            if (_can(CommunityPermissions.manageRoles) && roles.isNotEmpty) ...<Widget>[
              const Divider(),
              for (final role in roles)
                CheckboxListTile(
                  value: member.roleIds.contains(role.id),
                  title: Text(role.name),
                  onChanged: (checked) {
                    final next = <String>{...member.roleIds};
                    if (checked == true) {
                      next.add(role.id);
                    } else {
                      next.remove(role.id);
                    }
                    unawaited(_setRoles(member, next.toList(growable: false)));
                  },
                ),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _moderate(CommunityMember member, String action, {int? minutes}) async {
    try {
      await sl<CommunityRepository>().moderate(widget.communityId, member.userId, action: action, minutes: minutes);
      _toast('${action[0].toUpperCase()}${action.substring(1)} applied to @${member.username}.');
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _setRoles(CommunityMember member, List<String> roleIds) async {
    try {
      await sl<CommunityRepository>().setMemberRoles(widget.communityId, member.userId, roleIds);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _createRole() async {
    final nameController = TextEditingController();
    final selected = <int>{CommunityPermissions.viewChannel, CommunityPermissions.sendMessages};
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setInnerState) => AlertDialog(
          title: const Text('New role'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Role name')),
                const SizedBox(height: 8),
                for (final entry in CommunityPermissions.labels.entries)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(entry.key),
                    title: Text(entry.value, style: const TextStyle(fontSize: 13)),
                    onChanged: (checked) => setInnerState(() {
                      if (checked == true) {
                        selected.add(entry.key);
                      } else {
                        selected.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Create')),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    nameController.dispose();
    if (result != true || name.isEmpty) return;
    try {
      var mask = 0;
      for (final permission in selected) {
        mask |= permission;
      }
      await sl<CommunityRepository>().createRole(widget.communityId, name: name, permissions: mask);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _deleteRole(CommunityRole role) async {
    try {
      await sl<CommunityRepository>().deleteRole(role.id);
      await _load();
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _invite() async {
    try {
      final code = await sl<CommunityRepository>().createInvite(widget.communityId);
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
              Text('Invite code', style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 8),
              SelectableText(code, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              const Text('Anyone with this code can join. It expires in a week.', style: TextStyle(fontSize: 12.5)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  _toast('Invite copied.');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy code'),
              ),
            ],
          ),
        ),
      );
    } on AppException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _leave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this community?'),
        content: const Text('You can rejoin later if it is public. Your messages stay.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await sl<CommunityRepository>().leave(widget.communityId);
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
    final overview = _overview;
    return Scaffold(
      appBar: AppBar(
        title: Text(overview?.community.name ?? 'Community'),
        actions: <Widget>[
          if (_can(CommunityPermissions.createInvites))
            IconButton(
              tooltip: 'Invite',
              icon: const Icon(Icons.person_add_alt_1_rounded),
              onPressed: _invite,
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'channels':
                  unawaited(_createChannel());
                case 'voice':
                  unawaited(_createChannel(kind: 'voice'));
                case 'leave':
                  unawaited(_leave());
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              if (_can(CommunityPermissions.manageChannels)) ...<PopupMenuEntry<String>>[
                const PopupMenuItem<String>(value: 'channels', child: Text('New text channel')),
                const PopupMenuItem<String>(value: 'voice', child: Text('New voice room')),
              ],
              const PopupMenuItem<String>(value: 'leave', child: Text('Leave community')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const <Widget>[
            Tab(text: 'Channels'),
            Tab(text: 'Members'),
            Tab(text: 'Roles'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : overview == null
              ? InlineError(message: _error ?? 'This community could not be loaded.', onRetry: _load)
              : TabBarView(
                  controller: _tabs,
                  children: <Widget>[
                    _ChannelsTab(
                      overview: overview,
                      voiceChannelId: _voiceChannelId,
                      canManage: _can(CommunityPermissions.manageChannels),
                      onOpenText: (channel) {
                        final chatId = channel.chatId;
                        if (chatId == null) {
                          _toast('That channel has no conversation yet.');
                          return;
                        }
                        context.push(Routes.chat(chatId));
                      },
                      onToggleVoice: _toggleVoice,
                      onLongPressChannel: _channelSheet,
                      onAddChannel: _createChannel,
                    ),
                    _MembersTab(
                      overview: overview,
                      onMemberTap: _memberSheet,
                    ),
                    _RolesTab(
                      overview: overview,
                      canManage: _can(CommunityPermissions.manageRoles),
                      onCreate: _createRole,
                      onDelete: _deleteRole,
                    ),
                  ],
                ),
    );
  }
}

class _ChannelsTab extends StatelessWidget {
  const _ChannelsTab({
    required this.overview,
    required this.voiceChannelId,
    required this.canManage,
    required this.onOpenText,
    required this.onToggleVoice,
    required this.onLongPressChannel,
    required this.onAddChannel,
  });

  final CommunityOverview overview;
  final String? voiceChannelId;
  final bool canManage;
  final void Function(CommunityChannel) onOpenText;
  final void Function(CommunityChannel) onToggleVoice;
  final void Function(CommunityChannel) onLongPressChannel;
  final Future<void> Function({String kind, String? categoryId}) onAddChannel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Channels are grouped exactly as the server returns them: a category is a
    // folder, and an uncategorised channel belongs to the implicit top group.
    final groups = <String, List<CommunityChannel>>{};
    final names = <String, String>{'': 'General'};
    for (final category in overview.categories) {
      groups[category.id] = <CommunityChannel>[];
      names[category.id] = category.name;
    }
    groups.putIfAbsent('', () => <CommunityChannel>[]);
    for (final channel in overview.channels) {
      final key = channel.categoryId != null && groups.containsKey(channel.categoryId) ? channel.categoryId! : '';
      groups.putIfAbsent(key, () => <CommunityChannel>[]).add(channel);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 96),
      children: <Widget>[
        if (overview.community.description != null && overview.community.description!.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              overview.community.description!.trim(),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ),
        for (final entry in groups.entries)
          if (entry.value.isNotEmpty || entry.key.isEmpty) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: <Widget>[
                  Text(
                    names[entry.key] ?? 'Channels',
                    style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: 0.7,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (canManage)
                    InkWell(
                      onTap: () => onAddChannel(categoryId: entry.key.isEmpty ? null : entry.key),
                      child: Icon(Icons.add_rounded, size: 18, color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            for (final channel in entry.value)
              _ChannelTile(
                channel: channel,
                joined: voiceChannelId == (channel.chatId ?? channel.id),
                people: overview.voice.where((voice) => voice.channelId == (channel.chatId ?? channel.id)).toList(growable: false),
                onTap: () => channel.kind == 'voice' ? onToggleVoice(channel) : onOpenText(channel),
                onLongPress: canManage && channel.kind != 'voice' ? () => onLongPressChannel(channel) : null,
              ),
          ],
        if (canManage)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: OutlinedButton.icon(
              onPressed: () => onAddChannel(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create a channel'),
            ),
          ),
      ],
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.joined,
    required this.people,
    required this.onTap,
    this.onLongPress,
  });

  final CommunityChannel channel;
  final bool joined;
  final List<VoiceState> people;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isVoice = channel.kind == 'voice';
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        child: Row(
          children: <Widget>[
            Icon(
              isVoice ? (joined ? Icons.graphic_eq_rounded : Icons.volume_up_outlined) : Icons.tag_rounded,
              size: 19,
              color: joined ? Brand.seed : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          channel.name,
                          style: TextStyle(fontWeight: FontWeight.w600, color: joined ? Brand.seed : null),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (channel.isPrivate) ...<Widget>[
                        const SizedBox(width: 6),
                        Icon(Icons.lock_rounded, size: 13, color: scheme.onSurfaceVariant),
                      ],
                      if (channel.slowmodeSeconds > 0) ...<Widget>[
                        const SizedBox(width: 6),
                        Icon(Icons.timer_outlined, size: 13, color: scheme.onSurfaceVariant),
                      ],
                      if (channel.unreadCount > 0) ...<Widget>[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                          decoration: BoxDecoration(color: Brand.accent, borderRadius: BorderRadius.circular(10)),
                          child: Text(
                            '${channel.unreadCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (channel.topic != null && channel.topic!.isNotEmpty)
                    Text(
                      channel.topic!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  if (isVoice && people.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final voice in people)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                PersonAvatar(
                                  name: voice.displayName ?? voice.username ?? 'Member',
                                  path: voice.avatarPath,
                                  size: 22,
                                  isOnline: true,
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  voice.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                  size: 13,
                                  color: voice.isMuted ? scheme.error : scheme.onSurfaceVariant,
                                ),
                                if (voice.isStreaming) ...<Widget>[
                                  const SizedBox(width: 3),
                                  const Icon(Icons.screen_share_rounded, size: 13, color: Brand.live),
                                ],
                              ],
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersTab extends StatefulWidget {
  const _MembersTab({required this.overview, required this.onMemberTap});

  final CommunityOverview overview;
  final void Function(CommunityMember) onMemberTap;

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final roles = <String, CommunityRole>{
      for (final role in widget.overview.roles) role.id: role,
    };
    final members = widget.overview.members
        .where((member) => _query.isEmpty || member.username.toLowerCase().contains(_query.toLowerCase()))
        .toList(growable: false);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Filter members', prefixIcon: Icon(Icons.search_rounded)),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Expanded(
          child: members.isEmpty
              ? const EmptyState(title: 'No members match', message: 'Try a different name.', icon: Icons.person_search_outlined)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 90),
                  itemCount: members.length,
                  itemBuilder: (context, index) {
                    final member = members[index];
                    final memberRoles = member.roleIds
                        .map((id) => roles[id])
                        .whereType<CommunityRole>()
                        .toList(growable: false);
                    return ListTile(
                      leading: PersonAvatar(
                        name: member.displayName ?? member.username,
                        path: member.avatarPath,
                        isOnline: member.isOnline,
                      ),
                      title: Text(member.nickname?.isNotEmpty == true ? member.nickname! : (member.displayName ?? member.username)),
                      subtitle: Text(handleOf(member.username)),
                      trailing: Wrap(
                        spacing: 4,
                        children: <Widget>[
                          for (final role in memberRoles.take(2))
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: _roleColor(role.color).withOpacity(0.16),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                role.name,
                                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _roleColor(role.color)),
                              ),
                            ),
                        ],
                      ),
                      onTap: () => widget.onMemberTap(member),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Color _roleColor(String value) {
  final text = value.replaceFirst('#', '');
  if (text.length != 6) return Brand.seed;
  final parsed = int.tryParse(text, radix: 16);
  return parsed == null ? Brand.seed : Color(0xFF000000 | parsed);
}

class _RolesTab extends StatelessWidget {
  const _RolesTab({required this.overview, required this.canManage, required this.onCreate, required this.onDelete});

  final CommunityOverview overview;
  final bool canManage;
  final VoidCallback onCreate;
  final void Function(CommunityRole) onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: <Widget>[
        Text(
          canManage
              ? 'Roles grant permissions. A member can hold several; the union is what they can do.'
              : 'Roles in this community. Only people who can manage roles may change them.',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4),
        ),
        const SizedBox(height: 12),
        for (final role in overview.roles)
          Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 8),
            color: scheme.surfaceContainerHighest.withOpacity(0.5),
            child: ListTile(
              leading: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: _roleColor(role.color), shape: BoxShape.circle),
              ),
              title: Text(role.name),
              subtitle: Text(
                '${role.memberCount} member${role.memberCount == 1 ? '' : 's'}'
                '${role.isDefault ? ' · default' : ''}'
                ' · ${_permissionCount(role.permissions)} permissions',
              ),
              trailing: canManage && !role.isDefault
                  ? IconButton(
                      tooltip: 'Delete role',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: () => onDelete(role),
                    )
                  : null,
            ),
          ),
        if (canManage) ...<Widget>[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Create a role'),
          ),
        ],
      ],
    );
  }

  int _permissionCount(int mask) {
    var count = 0;
    for (final permission in CommunityPermissions.labels.keys) {
      if (CommunityPermissions.has(mask, permission)) count++;
    }
    return count;
  }
}
