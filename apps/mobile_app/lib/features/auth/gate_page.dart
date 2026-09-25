import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/errors.dart';
import 'auth_bloc.dart';

/// Only the server can change profiles.access_state; a client cannot bypass a
/// moderation restriction by handing over an unrelated Google/Telegram token.
class GatePage extends StatelessWidget {
  const GatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: BlocBuilder<AuthBloc, AuthUiState>(
          builder: (context, state) {
            final blocked = state.status == AppStatus.blocked;
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
                        blocked ? 'MessengerX is not available for this account' : 'Checking account access',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        state.profile?.accessStateReason ??
                            'Your account is not active yet. Refresh its status or ask the project operator for help.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      if (state.error is AppException) ...<Widget>[
                        const SizedBox(height: 20),
                        Text((state.error! as AppException).message,
                            textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.error)),
                      ],
                      const SizedBox(height: 28),
                      if (!blocked)
                        FilledButton(
                          onPressed: state.busy
                              ? null
                              : () => context.read<AuthBloc>().add(const AuthProfileRefreshRequested()),
                          child: state.busy ? const Text('Refreshing…') : const Text('Refresh status'),
                        ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => context.read<AuthBloc>().add(const AuthSignOutRequested()),
                        child: const Text('Sign out'),
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
}
