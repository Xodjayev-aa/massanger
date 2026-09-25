import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import 'auth_bloc.dart';

/// Google or independent Telegram OIDC sign-in (when the host enables it).
/// Neither sign-in method creates a TDLib session: connecting Telegram for
/// conversations still requires the separate phone/code wizard after sign-in.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn({required bool withTelegram}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The bloc's auth listener drives navigation after the browser returns.
      final auth = context.read<AuthBloc>();
      if (withTelegram) {
        await auth.signInWithTelegram();
      } else {
        await auth.signInWithGoogle();
      }
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final telegramAvailable = context.read<AuthBloc>().telegramLoginEnabled;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _Wordmark(),
                  const SizedBox(height: 28),
                  Text(
                    'One app for your Telegram chats and your people.',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    telegramAvailable
                        ? 'Choose Google or Telegram to sign in. To message people on Telegram, connect your account with its phone number and login code afterward.'
                        : 'Sign in with Google. Telegram sign-in needs server setup; to message Telegram users, connect your account by phone and code afterward.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _signIn(withTelegram: false),
                    icon: _busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.g_mobiledata_rounded, size: 28),
                    label: const Text('Continue with Google'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy || !telegramAvailable ? null : () => _signIn(withTelegram: true),
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Continue with Telegram'),
                  ),
                  if (!telegramAvailable) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      'Telegram sign-in awaits the hosted provider setup. Google sign-in still works once configured.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    _ErrorNote(message: _error!),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Google does not grant access to Gmail or Drive and does not prove account age. '
                    'Telegram approval is not phone/code sign-in. Standalone in-app phone/code identity '
                    'sign-in is not implemented. The two methods create separate MessengerX accounts unless '
                    'the identities are securely linked.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'This free website only hosts the app. Chatting with real Telegram users, and offline '
                    'Saved Messages notices, need a separate always-on worker with persistent storage. That '
                    'worker is not included. There is no signed public Android installer. On iPhone, use '
                    'Add to Home Screen — the PWA is the free install, not an App Store app.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(Icons.forum_rounded, color: theme.colorScheme.onPrimary, size: 24),
        ),
        const SizedBox(width: 12),
        Text('MessengerX', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withAlpha(90),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
        ],
      ),
    );
  }
}
