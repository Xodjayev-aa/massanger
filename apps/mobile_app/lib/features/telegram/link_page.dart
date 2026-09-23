import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/di.dart';
import '../../data/models.dart';
import '../../data/telegram_repository.dart';
import '../auth/auth_bloc.dart';
import '../chats/chats_bloc.dart';
import '../chats/widgets.dart';
import 'link_cubit.dart';

/// The Telegram link wizard: phone → code → 2FA password.
///
/// A link is deliberately *not* instant: the bridge owns the TDLib session, so the
/// app only ever hands credentials to the edge function and then waits. That is why
/// this screen shows a countdown and a "waiting for Telegram" state instead of a
/// spinner that implies the phone is doing the work.
class LinkPage extends StatelessWidget {
  const LinkPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<LinkCubit>(
      create: (context) => LinkCubit(sl<TelegramRepository>()),
      child: const _LinkView(),
    );
  }
}

class _LinkView extends StatelessWidget {
  const _LinkView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link Telegram'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () async {
            await context.read<LinkCubit>().cancel();
            if (context.mounted) context.pop();
          },
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<LinkCubit, LinkState>(
          listenWhen: (previous, next) => previous.linked != next.linked,
          listener: (context, state) {
            if (!state.linked) return;
            // Both the chat list (mirrored chats) and the panel need a reload.
            context.read<ChatsBloc>().add(const ChatsRefreshRequested());
            context.read<AuthBloc>().add(const AuthProfileRefreshRequested());
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Telegram connected.')));
            context.pop();
          },
          builder: (context, state) {
            if (state.linked) {
              return const Center(child: Text('Telegram is connected.'));
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _Steps(prompt: state.prompt),
                  const SizedBox(height: 24),
                  switch (state.prompt) {
                    LinkPrompt.phone => _PhoneStep(busy: state.isBusy, onSubmit: (phone) => context.read<LinkCubit>().submitPhone(phone)),
                    LinkPrompt.code => _CodeStep(
                        busy: state.isBusy,
                        note: state.note,
                        timeLeft: state.timeLeft,
                        onSubmit: (code) => context.read<LinkCubit>().submitCode(code),
                      ),
                    LinkPrompt.password => _PasswordStep(
                        busy: state.isBusy,
                        onSubmit: (password) => context.read<LinkCubit>().submitPassword(password),
                      ),
                    LinkPrompt.registration => const _RegistrationNotice(),
                    LinkPrompt.waiting => _WaitingPanel(note: state.note, busy: state.isBusy),
                  },
                  if (state.qrCode != null && state.qrCode!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 24),
                    _QrPanel(token: state.qrCode!),
                  ],
                  if (!state.sealed) ...<Widget>[
                    const SizedBox(height: 20),
                    InlineError(
                      message: 'This server cannot seal credentials (SEAL_KEY is unset), so a 2FA password '
                          'would travel as plain JSON inside the request. Linking from a development build is '
                          'fine; never use it for your real account.',
                    ),
                  ],
                  if (state.error != null) ...<Widget>[
                    const SizedBox(height: 20),
                    InlineError(message: state.error!),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'Massanger links an existing Telegram account. It does not register a new one, and it never '
                    'stores your code or password: both are encrypted for the bridge and dropped as soon as '
                    'Telegram accepts them.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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

class _Steps extends StatelessWidget {
  const _Steps({required this.prompt});

  final LinkPrompt prompt;

  static const List<String> _labels = <String>['Phone', 'Code', 'Connected'];

  @override
  Widget build(BuildContext context) {
    final index = switch (prompt) {
      LinkPrompt.phone => 0,
      LinkPrompt.code => 1,
      LinkPrompt.password => 1,
      LinkPrompt.registration => 1,
      LinkPrompt.waiting => 1,
    };
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        for (var i = 0; i < _labels.length; i++) ...<Widget>[
          Expanded(
            child: Column(
              children: <Widget>[
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= index ? scheme.primary : scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _labels[i],
                  style: TextStyle(
                    fontSize: 11.5,
                    color: i <= index ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (i != _labels.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _PhoneStep extends StatefulWidget {
  const _PhoneStep({required this.busy, required this.onSubmit});

  final bool busy;
  final ValueChanged<String> onSubmit;

  @override
  State<_PhoneStep> createState() => _PhoneStepState();
}

class _PhoneStepState extends State<_PhoneStep> {
  final TextEditingController _controller = TextEditingController(text: '+998');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('Your Telegram phone number', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.phone,
          autofillHints: const <String>[AutofillHints.telephoneNumber],
          decoration: const InputDecoration(
            hintText: '+998901112233',
            helperText: 'Include the country code. Telegram will send a code to this number.',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.busy ? null : () => widget.onSubmit(_controller.text),
          child: widget.busy ? const _BusyLabel('Sending…') : const Text('Send code'),
        ),
      ],
    );
  }
}

class _CodeStep extends StatefulWidget {
  const _CodeStep({required this.busy, required this.onSubmit, this.note, this.timeLeft});

  final bool busy;
  final ValueChanged<String> onSubmit;
  final String? note;
  final Duration? timeLeft;

  @override
  State<_CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends State<_CodeStep> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('Code from Telegram', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.text,
          maxLength: 20,
          style: const TextStyle(letterSpacing: 3, fontSize: 20),
          decoration: const InputDecoration(
            hintText: '1A2B3',
            counterText: '',
            helperText: 'Telegram sends it inside the app first — check Telegram, not SMS.',
          ),
          onSubmitted: (value) => widget.onSubmit(value),
        ),
        if (widget.note != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(widget.note!, style: theme.textTheme.bodySmall),
          ),
        if (widget.timeLeft != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'This request expires in ${widget.timeLeft!.inMinutes}:${widget.timeLeft!.inSeconds.remainder(60).toString().padLeft(2, '0')}.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        FilledButton(
          onPressed: widget.busy ? null : () => widget.onSubmit(_controller.text),
          child: widget.busy ? const _BusyLabel('Checking…') : const Text('Continue'),
        ),
      ],
    );
  }
}

class _PasswordStep extends StatefulWidget {
  const _PasswordStep({required this.busy, required this.onSubmit});

  final bool busy;
  final ValueChanged<String> onSubmit;

  @override
  State<_PasswordStep> createState() => _PasswordStepState();
}

class _PasswordStepState extends State<_PasswordStep> {
  final TextEditingController _controller = TextEditingController();
  bool _visible = false;

  @override
  void dispose() {
    // The field is wiped as soon as the step is done: no 2FA password outlives the
    // widget that asked for it.
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('Two-step verification password', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          obscureText: !_visible,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Your Telegram 2FA password',
            suffixIcon: IconButton(
              onPressed: () => setState(() => _visible = !_visible),
              icon: Icon(_visible ? Icons.visibility_off_rounded : Icons.visibility_rounded),
            ),
            helperText: 'Encrypted for the bridge the moment you tap continue.',
          ),
          onSubmitted: (value) {
            widget.onSubmit(value);
            _controller.clear();
          },
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.busy ? null : () {
            widget.onSubmit(_controller.text);
            _controller.clear();
          },
          child: widget.busy ? const _BusyLabel('Checking…') : const Text('Unlock'),
        ),
      ],
    );
  }
}

class _RegistrationNotice extends StatelessWidget {
  const _RegistrationNotice();

  @override
  Widget build(BuildContext context) {
    return InlineError(
      message: 'That number does not have a Telegram account yet. Massanger links an existing one — '
          'install Telegram, register the number, then come back.',
    );
  }
}

class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel({required this.busy, this.note});

  final bool busy;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        SizedBox.square(
          dimension: 34,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 14),
        Text(busy ? 'Telegram is answering…' : 'Waiting for Telegram', style: theme.textTheme.titleSmall),
        if (note != null && note!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(note!, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// The bridge exports a TDLib `login_token`; Telegram's "pair device" screen scans it.
class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            Text('Or scan this in Telegram', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Telegram → Settings → Devices → Link Desktop Device',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: QrImageView(
                data: token,
                size: 196,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: token));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Token copied.')));
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy token'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusyLabel extends StatelessWidget {
  const _BusyLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary)),
        const SizedBox(width: 10),
        Text(text),
      ],
    );
  }
}
