import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../core/formatting.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';
import '../chats/widgets.dart';
import 'telegram_cubit.dart';

/// Telegram panel: connection state, what the bridge is allowed to do, and the
/// per-chat switches. Everything here maps to a definer RPC that also enforces the
/// age gate, so the panel can never grant itself more than the account has.
class TelegramPage extends StatelessWidget {
  const TelegramPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<TelegramCubit>(
      create: (context) => TelegramCubit(sl<TelegramRepository>())..load(),
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
  final ValueChanged<bool> onChanged;

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
    'to_app': 'Telegram → app',
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
          PopupMenuItem<String>(value: 'to_app', child: Text('Telegram → app only')),
          PopupMenuItem<String>(value: 'to_telegram', child: Text('App → Telegram only')),
          PopupMenuItem<String>(value: 'off', child: Text('Off for this chat')),
        ],
      ),
    );
  }
}
