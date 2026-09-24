import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import 'auth_bloc.dart';

/// Google sign-in for MessengerX. Telegram phone + code is a separate TDLib
/// linking step after sign-in; standalone Telegram identity sign-in is not yet
/// implemented and must not be advertised as a working option.
class SignInPage extends StatefulWidget {
  const SignInPage({super.key});

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The Supabase SDK resolves once the OAuth redirect lands back in the app;
      // the bloc's auth listener then drives the navigation from here.
      await context.read<AuthBloc>().signInWithGoogle();
    } on AppException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                    'Sign in with Google to use MessengerX. To message people on Telegram, '
                    'connect your own Telegram account with its phone number and login code after signing in.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _busy ? null : _signIn,
                    icon: _busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.g_mobiledata_rounded, size: 28),
                    label: Text(_busy ? 'Opening Google…' : 'Continue with Google'),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    _ErrorNote(message: _error!),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Google sign-in does not grant access to your Gmail or Drive. '
                    'Telegram will send a code when you choose to connect your account.',
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
