import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

import '../data/account_repository.dart';
import '../data/chat_repository.dart';
import '../data/telegram_repository.dart';
import '../features/auth/auth_bloc.dart';
import '../features/chats/chats_bloc.dart';
import 'di.dart';
import 'incoming_notices.dart';
import 'router.dart';
import 'theme.dart';

/// The widget the entry point runs.
///
/// Two blocs live above the router on purpose: [AuthBloc] owns the session and the
/// eligibility gate (the router's `redirect` listens to it), and [ChatsBloc] owns
/// the feed so the unread badge and the last-message previews survive opening a
/// thread. Every other bloc is scoped to the screen that needs it.
class MessengerXApp extends StatefulWidget {
  const MessengerXApp({super.key});

  @override
  State<MessengerXApp> createState() => _MessengerXAppState();
}

class _MessengerXAppState extends State<MessengerXApp> with WidgetsBindingObserver {
  late final AuthBloc _auth;
  late final ChatsBloc _chats;

  /// Built once. Rebuilding a GoRouter on each auth change would throw away the
  /// navigation stack, which is the bug this field exists to prevent.
  late final GoRouter _router;
  Timer? _heartbeat;

  /// go_router wants a [Listenable], and a bloc is a stream — this bridge is what
  /// makes `redirect` re-run on an auth change without rebuilding the router.
  final ValueNotifier<int> _routerTick = ValueNotifier<int>(0);
  StreamSubscription<AuthUiState>? _routerTickSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth = AuthBloc(sl<AccountRepository>(), sl<TelegramRepository>())..add(const AuthStarted());
    _chats = ChatsBloc(sl<ChatRepository>(), auth: _auth);
    _router = buildRouter(_auth, _routerTick);
    _routerTickSub = _auth.stream.listen((_) => _routerTick.value++);
    _startHeartbeat();
  }

  /// Presence is refreshed only while foregrounded: a background wake that updates
  /// `last_seen_at` would advertise every contact as online at 3 a.m.
  void _startHeartbeat() {
    _heartbeat?.cancel();
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) {
      if (_auth.state.status == AppStatus.ready) unawaited(_auth.refreshPresence());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_auth.refreshPresence());
      unawaited(_chats.refresh());
      _startHeartbeat();
      return;
    }
    _heartbeat?.cancel();
    _heartbeat = null;
    unawaited(_chats.pause());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    unawaited(_routerTickSub?.cancel() ?? Future<void>.value());
    _routerTick.dispose();
    unawaited(_chats.close());
    unawaited(_auth.close());
    unawaited(disposeDependencies());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The provider bound is `T extends StateStreamableSource<Object?>`, so annotating
    // this list `List<BlocProvider<Object>>` does not compile. flutter_bloc 8.1 does not
    // export the common supertype's name either, so the type is left to inference.
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthBloc>.value(value: _auth),
        BlocProvider<ChatsBloc>.value(value: _chats),
      ],
      child: BlocBuilder<AuthBloc, AuthUiState>(
        buildWhen: (previous, next) => previous.status != next.status,
        builder: (context, state) {
          return MaterialApp.router(
            title: 'MessengerX',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: ThemeMode.system,
            routerConfig: _router,
            builder: (context, child) => IncomingNotices(
              auth: _auth,
              chats: _chats,
              telegram: sl<TelegramRepository>(),
              client: sl<SupabaseClient>(),
              child: _coldStartCover(
                context,
                child,
                covered: state.status == AppStatus.unknown,
              ),
            ),
          );
        },
      ),
    );
  }

  /// A cold start restores the session asynchronously. Covering the first frame
  /// (instead of replacing it) means the router still builds, so a deep link
  /// survives the restore instead of bouncing to the chat list.
  Widget _coldStartCover(BuildContext context, Widget? child, {required bool covered}) {
    if (!covered) return child ?? const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child ?? const SizedBox.shrink(),
        ColoredBox(
          color: scheme.surface,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
        ),
      ],
    );
  }
}
