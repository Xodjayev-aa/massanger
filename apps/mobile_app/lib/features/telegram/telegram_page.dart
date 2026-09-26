import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/models.dart';
import '../../data/push_repository.dart';
import '../../data/telegram_repository.dart';
import '../chats/widgets.dart';
import 'telegram_cubit.dart';

/// Telegram panel: connection state, what the bridge is allowed to do, and the
/// per-chat switches. Everything here maps to a definer RPC that enforces
/// account access, so the panel cannot grant itself more than the server allows.
class TelegramPage extends StatelessWidget {
  const TelegramPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<TelegramCubit>(
      create: (context) => TelegramCubit(sl<TelegramRepository>(), sl<PushRepository>())..load(),
      child: const _TelegramView(),
    );
  }
}

class _TelegramView extends StatelessWidget {
  const _TelegramView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Telegram'), actions: <Widget>[
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () => context.read<TelegramCubit>().load(),
        ),
      ]),
      body: SafeArea(
        child: BlocConsumer<TelegramCubit, TelegramPanel>(
          listenWhen: (previous, next) => previous.error == null && next.error != null,
          listener: (context, state) {
            final error = state.error;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(error is AppException ? error.message : '$error')),
            );
          },
          builder: (context, state) {
            if (state.status == TelegramLoadStatus.loading && state.account == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final account = state.account ?? const TelegramStatus();
            return RefreshIndicator(
              onRefresh: () => context.read<TelegramCubit>().load(),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: <Widget>[
                  _ConnectionCard(account: account, busy: state.busy),
                  const _SectionTitle('Notifications'),
                  _PreferenceRow(
                    title: 'Offline alerts in Telegram',
                    subtitle: 'A durable worker can fold offline notices into your own Saved Messages. This website host is not that worker, so delivery is not available yet.',
                    value: state.pushPreferences?.telegram ?? false,
                    onChanged: account.isLinked && !state.busy && state.pushPreferences != null
                        ? (value) => context.read<TelegramCubit>().setPushPreferences(telegram: value)
                        : null,
                  ),
                  _PreferenceRow(
                    title: 'Show message previews',
                    subtitle: 'Also controls in-app banners. Off hides sender and text; banners still appear while the app is open.',
                    value: state.pushPreferences?.preview ?? false,
                    onChanged: !state.busy && state.pushPreferences != null
                        ? (value) => context.read<TelegramCubit>().setPushPreferences(preview: value)
                        : null,
                  ),
                  // The one delivery path that needs no worker of ours running:
                  // the browser's own push service holds the connection and the
                  // service worker draws the notification. Hidden entirely on
                  // Android/iOS and on browsers that cannot do it, rather than
                  // offering a switch that cannot work.
                  if (state.browserPush != null && !state.browserPush!.unavailable)
                    _PreferenceRow(
                      title: 'Browser notifications',
                      subtitle: _browserPushSubtitle(state.browserPush!),
                      value: state.browserPush!.enabled,
                      onChanged: state.busy ? null : (value) => context.read<TelegramCubit>().setBrowserPush(value),
                    ),
                  if (state.browserPush != null && state.browserPush!.thisBrowserRegistered)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: state.busy ? null : () => context.read<TelegramCubit>().forgetBrowser(),
                          child: const Text('Remove this browser'),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Text(
                      'No APNs or FCM: browser notifications come from this site through your browser\'s own push service, and Telegram handles the rest. No alert is sent for a muted or read chat, or for a message your Telegram already received.',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (account.isLinked || account.mirroredChats > 0) ...<Widget>[
                    const _SectionTitle('What the bridge may do'),
                    _PreferenceRow(
                      title: 'Mirror Telegram chats into MessengerX',
                      subtitle: 'Turn this off to stop importing new Telegram messages. Existing chats stay.',
                      value: account.mirrorToApp,
                      onChanged: (value) => context.read<TelegramCubit>().setPreferences(mirrorToApp: value),
                    ),
                    _PreferenceRow(
                      title: 'Download voice notes',
                      subtitle: 'Voice notes are fetched and re-hosted, so they play in MessengerX and in Telegram.',
                      value: account.autoDownloadVoice,
                      onChanged: (value) => context.read<TelegramCubit>().setPreferences(autoDownloadVoice: value),
                    ),
                    _PreferenceRow(
                      title: 'Download photos',
                      subtitle: 'Larger downloads, and the reason a first sync can take a minute.',
                      value: account.autoDownloadMedia,
                      onChanged: (value) => context.read<TelegramCubit>().setPreferences(autoDownloadMedia: value),
                    ),
                    _DirectionPicker(
                      value: account.syncDirection,
                      onChanged: (value) => context.read<TelegramCubit>().setPreferences(syncDirection: value),
                    ),
                    const _SectionTitle('Chats'),
                    if (state.chats.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Text(
                          'No Telegram chats discovered yet. Send or receive one message in Telegram and refresh.',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ...state.chats.map((chat) => _MirrorRow(chat: chat)),
                  ] else
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Link your Telegram account and MessengerX will mirror the chats you choose, in both directions.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.account, required this.busy});

  final TelegramStatus account;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linked = account.isLinked;
    return Card.outlined(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                TelegramBadge(authState: account.authState),
                const Spacer(),
                if (busy) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 12),
            Text(account.headline, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'The website host is not a Telegram worker. Linking, chatting with real Telegram users, and '
              'offline Saved Messages notices stay unavailable until a separate always-on worker with persistent '
              'storage is running. Phone/code here is not MessengerX identity sign-in.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (account.note != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(account.note!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            if (account.lastError != null) ...<Widget>[
              const SizedBox(height: 8),
              Text('Last error: ${account.lastError}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ],
            if (account.lastSyncAt != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Last sync ${ChatFormatting.dayLabel(account.lastSyncAt!)} ${ChatFormatting.clock(account.lastSyncAt!)} · ${account.mirroredChats} chat(s) mirrored',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                FilledButton(
                  onPressed: () => context.push(Routes.telegramLink),
                  child: Text(linked ? 'Re-link' : 'Link Telegram'),
                ),
                if (linked) ...<Widget>[
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Unlink Telegram?'),
                          content: const Text(
                            'MessengerX stops mirroring immediately and the bridge closes the TDLib session. '
                            'Your imported chats and messages stay in MessengerX.',
                          ),
                          actions: <Widget>[
                            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Unlink')),
                          ],
                        ),
                      );
                      if (confirmed == true && context.mounted) await context.read<TelegramCubit>().unlink();
                    },
                    child: const Text('Unlink'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _PreferenceRow extends StatelessWidget {
  const _PreferenceRow({required this.title, required this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
      isThreeLine: true,
    );
  }
}

class _DirectionPicker extends StatelessWidget {
  const _DirectionPicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const Map<String, String> _labels = <String, String>{
    'both': 'Two-way',
    'from_telegram': 'Telegram → app',
    'to_telegram': 'App → Telegram',
    'off': 'Off',
  };

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('Sync direction', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
      subtitle: const Text('Applies to the whole account; each chat can narrow it further.', style: TextStyle(fontSize: 12.5)),
      trailing: PopupMenuButton<String>(
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (context) => _labels.entries
            .map((entry) => PopupMenuItem<String>(value: entry.key, child: Text(entry.value)))
            .toList(growable: false),
      ),
    );
  }
}

class _MirrorRow extends StatelessWidget {
  const _MirrorRow({required this.chat});

  final MirroredChat chat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: chat.chatId == null ? null : () => context.push(Routes.chat(chat.chatId!)),
      leading: PersonAvatar(name: chat.title, size: 36),
      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        chat.isMirrored
            ? 'Telegram ${chat.telegramChatId} · ${chat.directionLabel}'
            : 'Not imported yet · ${chat.directionLabel}',
        style: theme.textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Per-chat sync',
        onSelected: (direction) {
          final chatId = chat.chatId;
          if (chatId == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Import this chat first: send it one message.')),
            );
            return;
          }
          context.read<TelegramCubit>().setChatSync(chatId: chatId, direction: direction);
        },
        itemBuilder: (context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'both', child: Text('Two-way')),
          PopupMenuItem<String>(value: 'from_telegram', child: Text('Telegram → app only')),
          PopupMenuItem<String>(value: 'to_telegram', child: Text('App → Telegram only')),
          PopupMenuItem<String>(value: 'off', child: Text('Off for this chat')),
        ],
      ),
    );
  }
}

/// One line, in the user's words, about why the browser switch looks the way it
/// does. Every state here has a different fix, so none of them may share a
/// generic "not available" string.
String _browserPushSubtitle(BrowserPushState push) {
  if (push.blocked) {
    return 'Notifications are blocked for this site. Allow them in your browser settings, then turn this on.';
  }
  if (!push.bridge.supported) {
    return 'This browser cannot show notifications. On an iPhone, add MessengerX to the Home Screen first.';
  }
  if (!push.enabled) {
    return 'Get a notification on this device when a message arrives and the app is closed.';
  }
  if (!push.thisBrowserRegistered) {
    return 'On for ${push.devices.length} browser${push.devices.length == 1 ? '' : 's'}, but not this one. Turn it off and on to add this browser.';
  }
  return push.devices.length <= 1
      ? 'On for this browser.'
      : 'On for this browser and ${push.devices.length - 1} other'
          '${push.devices.length == 2 ? '' : 's'}.';
}
