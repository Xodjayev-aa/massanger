import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../data/account_repository.dart';
import '../../data/models.dart';
import '../auth/auth_bloc.dart';
import '../chats/widgets.dart';
import 'profile_cubit.dart';

/// The account screen: identity, what Google told us, and the exit.
///
/// The Google age fields are shown read-only on purpose. They are written by the
/// gate and a user-editable copy of them would be the first hole in the rule.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ProfileCubit>(
      create: (context) => ProfileCubit(sl<AccountRepository>())..load(),
      child: const _ProfileView(),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your account'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Telegram',
            icon: const Icon(Icons.send_rounded),
            onPressed: () => context.push(Routes.telegram),
          ),
        ],
      ),
      body: SafeArea(
        child: BlocBuilder<ProfileCubit, ProfileState>(
          builder: (context, state) {
            if (state.status == ProfileStatus.loading) return const Center(child: CircularProgressIndicator());
            final profile = state.profile;
            if (profile == null) {
              return ListView(
                children: <Widget>[
                  const SizedBox(height: 40),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: InlineError(
                      message: state.error is AppException ? (state.error! as AppException).message : 'Your profile could not be loaded.',
                      onRetry: () => context.read<ProfileCubit>().load(),
                    ),
                  ),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: <Widget>[
                const SizedBox(height: 12),
                Center(
                  child: PersonAvatar(name: profile.displayName, path: profile.avatar, size: 92),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '@${profile.username}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 16),
                _IdentityEditor(profile: profile, saving: state.saving),
                const Divider(height: 32),
                const _SectionHeader('Account age'),
                _InfoRow(label: 'Access state', value: profile.accessState.replaceAll('_', ' ')),
                _InfoRow(
                  label: 'Google account age',
                  value: profile.googleAccountAgeDays == null ? 'not recorded' : '${profile.googleAccountAgeDays} days',
                ),
                _InfoRow(label: 'Verified by', value: profile.eligibilityMethod ?? '—'),
                _InfoRow(label: 'Attempts', value: '${profile.eligibilityAttempts}'),
                if (profile.accessStateReason != null) _InfoRow(label: 'Note', value: profile.accessStateReason!),
                const Divider(height: 32),
                const _SectionHeader('Google'),
                _InfoRow(label: 'Signed in as', value: profile.googleEmail ?? 'not linked'),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Sign out?'),
                          content: const Text(
                            'If Telegram is linked, Massanger unlinks it too so the bridge stops reading your chats. '
                            'Your messages stay on the server.',
                          ),
                          actions: <Widget>[
                            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sign out')),
                          ],
                        ),
                      );
                      if (confirmed == true && context.mounted) {
                        context.read<AuthBloc>().add(const AuthSignOutRequested());
                      }
                    },
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Sign out'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IdentityEditor extends StatefulWidget {
  const _IdentityEditor({required this.profile, required this.saving});

  final AccountProfile profile;
  final bool saving;

  @override
  State<_IdentityEditor> createState() => _IdentityEditorState();
}

class _IdentityEditorState extends State<_IdentityEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.profile.displayName);
  late final TextEditingController _bio = TextEditingController(text: widget.profile.bio);

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    try {
      final cubit = context.read<ProfileCubit>();
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 640, maxHeight: 640, imageQuality: 85);
      if (picked == null) return;
      await cubit.saveAvatar(File(picked.path), previousPath: widget.profile.avatarPath);
      if (!mounted) return;
      context.read<AuthBloc>().add(const AuthProfileRefreshRequested());
    } on AppException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: widget.saving ? null : _pickAvatar,
                  icon: const Icon(Icons.photo_camera_front_rounded, size: 18),
                  label: Text(widget.profile.avatarPath == null ? 'Choose a photo' : 'Change photo'),
                ),
              ),
              if (widget.profile.avatarPath != null)
                TextButton(onPressed: widget.saving ? null : () => context.read<ProfileCubit>().clearAvatar(), child: const Text('Remove')),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'Display name', counterText: ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bio,
            maxLines: 3,
            maxLength: 280,
            decoration: const InputDecoration(labelText: 'About you', counterText: ''),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: widget.saving
                ? null
                : () => context.read<ProfileCubit>().save(
                      displayName: _name.text.trim(),
                      bio: _bio.text.trim(),
                    ),
            child: widget.saving ? const Text('Saving…') : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
