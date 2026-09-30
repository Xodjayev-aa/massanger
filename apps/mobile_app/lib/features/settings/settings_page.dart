import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../data/push_repository.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../../data/telegram_repository.dart';
import '../auth/auth_bloc.dart';
import '../chats/widgets.dart';

/// One screen for everything that is about *you* rather than about other
/// people: appearance, notifications, privacy, the linked Telegram account and
/// the way out of the account.
///
/// The identity editor itself stays on the Profile tab (it needs the avatar
/// picker and the profile cubit); this page links to it instead of growing a
/// second copy that could drift.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<ProfileCard> _blocked = const <ProfileCard>[];
  bool _loadingBlocked = true;
  bool _pushOn = false;
  String? _telegramUsername;
  bool _telegramLinked = false;
  bool _savingPush = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await Future.wait<void>(<Future<void>>[_loadBlocked(), _loadPush(), _loadTelegram()]);
  }

  Future<void> _loadBlocked() async {
    try {
      final blocked = await sl<SocialRepository>().blockedUsers();
      if (mounted) {
        setState(() {
          _blocked = blocked;
          _loadingBlocked = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingBlocked = false);
    }
  }

  Future<void> _loadPush() async {
    try {
      final state = await sl<PushRepository>().load();
      if (mounted) setState(() => _pushOn = state.enabled);
    } catch (_) {
      // A deployment without the push function simply keeps the switch off.
    }
  }

  Future<void> _loadTelegram() async {
    try {
      final status = await sl<TelegramRepository>().status();
      if (!mounted) return;
      setState(() {
        _telegramLinked = status.isLinked;
        _telegramUsername = status.tgUsername;
      });
    } catch (_) {
      // Linking is optional; a failure here must not block the rest of the page.
    }
  }

  Future<void> _togglePush(bool value) async {
    setState(() => _savingPush = true);
    try {
      final state = value ? await sl<PushRepository>().turnOn() : await sl<PushRepository>().turnOff();
      if (mounted) setState(() => _pushOn = state.enabled);
    } on AppException catch (error) {
      _toast(error.message);
    } catch (_) {
      _toast('That change did not stick. Try again.');
    } finally {
      if (mounted) setState(() => _savingPush = false);
    }
  }

  Future<void> _unblock(ProfileCard person) async {
    try {
      await sl<SocialRepository>().unblock(person.id);
      if (mounted) setState(() => _blocked = _blocked.where((p) => p.id != person.id).toList(growable: false));
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
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: <Widget>[
          const _SectionHeader('Appearance'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: appThemeMode,
            builder: (context, mode, child) => Column(
              children: <Widget>[
                for (final option in const <ThemeMode>[ThemeMode.light, ThemeMode.dark, ThemeMode.system])
                  RadioListTile<ThemeMode>(
                    title: Text(switch (option) {
                      ThemeMode.light => 'Light',
                      ThemeMode.dark => 'Dark',
                      ThemeMode.system => 'Match the system',
                    }),
                    value: option,
                    groupValue: mode,
                    onChanged: (value) {
                      if (value != null) appThemeMode.value = value;
                    },
                  ),
              ],
            ),
          ),

          const _SectionHeader('Notifications'),
          SwitchListTile(
            title: const Text('Push notifications'),
            subtitle: const Text('Chats, follows, comments and payments, on every device you signed in on.'),
            value: _pushOn,
            onChanged: _savingPush ? null : _togglePush,
          ),
          ListTile(
            leading: const Icon(Icons.telegram_rounded),
            title: const Text('Telegram account'),
            subtitle: Text(
              _telegramLinked
                  ? 'Linked${_telegramUsername == null ? '' : ' as @$_telegramUsername'} — mirroring is on.'
                  : 'Not linked. Link it to see Telegram chats here.',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.telegram),
          ),

          const _SectionHeader('Privacy'),
          ListTile(
            leading: const Icon(Icons.person_rounded),
            title: const Text('Edit your profile'),
            subtitle: const Text('Display name, bio, avatar, and who may follow you.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.me),
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off_rounded),
            title: const Text('Blocked accounts'),
            subtitle: Text(
              _loadingBlocked
                  ? 'Loading…'
                  : _blocked.isEmpty
                      ? 'Nobody is blocked.'
                      : '${_blocked.length} blocked',
            ),
          ),
          if (_blocked.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                children: <Widget>[
                  for (final person in _blocked)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: PersonAvatar(name: person.name, path: person.avatarPath, size: 38),
                      title: Text(person.name),
                      subtitle: Text(person.handle),
                      trailing: TextButton(onPressed: () => _unblock(person), child: const Text('Unblock')),
                    ),
                ],
              ),
            ),

          const _SectionHeader('Your money and your bots'),
          ListTile(
            leading: const Icon(Icons.storefront_rounded),
            title: const Text('Stars store'),
            subtitle: const Text('Top-ups, custom tags, cosmetics.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.store),
          ),
          ListTile(
            leading: const Icon(Icons.account_balance_wallet_rounded),
            title: const Text('Wallet'),
            subtitle: const Text('Balance, ledger, gifts and payouts.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.wallet),
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_rounded),
            title: const Text('Bots'),
            subtitle: const Text('Build one with @BotFather, or install somebody else’s.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.bots),
          ),
          ListTile(
            leading: const Icon(Icons.groups_rounded),
            title: const Text('Communities'),
            subtitle: const Text('Servers you own or joined.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.communities),
          ),

          const _SectionHeader('Session'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Signing out only ends this device. Your Telegram link and your messages stay where they are.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => _confirmSignOut(context),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error, side: BorderSide(color: scheme.error.withOpacity(0.5))),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'MessengerX · free to run, no ads',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You can sign back in with the same Google account, or with Telegram if you linked it.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sign out')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.read<AuthBloc>().add(const AuthSignOutRequested());
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11.5,
          letterSpacing: 0.7,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}
