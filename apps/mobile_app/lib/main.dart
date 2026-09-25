import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/di.dart';
import 'core/env.dart';
import 'core/url_strategy.dart';

/// Entry point.
///
/// Startup order is deliberate: environment first (a mis-provisioned build must
/// fail before any network call), then Supabase, then dependency wiring, then the
/// widget tree. Anything thrown before `runApp` would otherwise surface as a blank
/// screen, so `main` reports it instead.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Path URLs (/chats/...) must be on before the router reads the browser
  // location, so a static host can rewrite a nested reload to index.html and
  // still open the same screen. Supabase.initialize below must finish the
  // OAuth code exchange before runApp leaves the site-root callback URL.
  configureAppUrlStrategy();

  const env = AppEnv.fromBuild;
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    // Replace with the crash reporter of choice (Sentry/Crashlytics); the shape of
    // the error is what matters, and it must never include request bodies.
    debugPrint('messengerx: ${details.exceptionAsString()}');
  };

  try {
    env.validate();
    await Supabase.initialize(
      url: env.supabaseUrl,
      // `anonKey` is deprecated in favour of `publishableKey`, which wants the new
      // `sb_publishable_…` format. A project still on legacy JWT keys passes its anon
      // key here, so the *name* is ignored rather than swapping in a value this
      // project may never have issued.
      // ignore: deprecated_member_use
      anonKey: env.supabaseAnonKey,
      // Local development against `supabase start` is http; production must be
      // https, which the platform enforces anyway.
      authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
      // Realtime's own throttle stays at the SDK default: the app subscribes to one
      // channel per open screen and the server caps the firehose, so a client-side
      // limit here would only hide a backlog that has to be drained anyway.
      debug: kDebugMode,
    );
    registerDependencies(env: env, client: Supabase.instance.client);
  } on Object catch (error, stack) {
    runApp(_FatalErrorApp(error: '$error', stack: '$stack'));
    return;
  }

  runApp(const MessengerXApp());
}

/// Shown when the build itself is broken (missing `--dart-define`), so a
/// mis-deployed APK says why instead of crashing on launch.
class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp({required this.error, required this.stack});

  final String error;
  final String stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('MessengerX cannot start', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Text(error, style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 24),
                Expanded(child: SingleChildScrollView(child: Text(stack, style: const TextStyle(fontSize: 11)))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
