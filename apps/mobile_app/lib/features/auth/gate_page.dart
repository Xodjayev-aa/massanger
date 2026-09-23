import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import 'auth_bloc.dart';

/// Shown while `access_state` is not `active`: either the age check still has to
/// pass, or it failed and the account is restricted.
///
/// The copy states the rule and what was found, because a user who is rejected for
/// a reason they cannot see will report it as a broken install.
class GatePage extends StatelessWidget {
  const GatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: BlocBuilder<AuthBloc, AuthUiState>(
          builder: (context, state) {
            final eligibility = state.eligibility;
            final blocked = state.status == AppStatus.blocked;
            final error = state.error;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Icon(
                        blocked ? Icons.block_rounded : Icons.hourglass_top_rounded,
                        size: 40,
                        color: blocked ? theme.colorScheme.error : theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        blocked ? 'Massanger is not available for this account' : 'Checking your Google account',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        eligibility?.reason.isNotEmpty == true
                            ? eligibility!.reason
                            : 'Massanger requires a Google account at least 366 days old. '
                                'This is verified with Google, on the server.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      if (eligibility != null && eligibility.accountAgeDays != null) ...<Widget>[
                        const SizedBox(height: 20),
                        _Fact(label: 'Account age found', value: '${eligibility.accountAgeDays} days'),
                        _Fact(label: 'Required', value: '${eligibility.minAgeDays} days'),
                        if (eligibility.method != null) _Fact(label: 'Determined from', value: _method(eligibility.method!)),
                        if (eligibility.attempts != null) _Fact(label: 'Attempts', value: '${eligibility.attempts}'),
                      ],
                      if (error is AppException) ...<Widget>[
                        const SizedBox(height: 20),
                        Text(error.message, textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 28),
                      if (!blocked)
                        FilledButton(
                          onPressed: state.busy
                              ? null
                              : () => context.read<AuthBloc>().add(const AuthEligibilityRequested(force: true)),
                          child: state.busy ? const Text('Checking…') : const Text('Check again'),
                        ),
                      if (blocked)
                        OutlinedButton(
                          onPressed: () => context.read<AuthBloc>().add(const AuthSignOutRequested()),
                          child: const Text('Sign out'),
                        ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => context.read<AuthBloc>().add(const AuthSignOutRequested()),
                        child: const Text('Use a different Google account'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static String _method(String value) => switch (value) {
        'gmail_profile' => 'the Gmail profile creation date',
        'gmail_oldest_message' => 'the oldest message in Gmail',
        'drive_oldest_file' => 'the oldest file in Drive',
        _ => value,
      };
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
