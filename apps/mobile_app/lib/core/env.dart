/// Compile-time configuration.
///
/// Nothing secret is compiled into the app: the anon key is public by design (RLS
/// does the enforcing) and the service-role key never reaches the client. Values
/// come from `--dart-define` so the same build can point at local, staging or
/// production without touching source.
class AppEnv {
  const AppEnv({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.functionBaseUrl,
    this.enableRealtime = true,
    this.telegramOidcEnabled = false,
    this.webRedirectUrl,
  });

  final String supabaseUrl;
  final String supabaseAnonKey;

  /// Set only when functions are deployed to a different host than [supabaseUrl]
  /// (a dedicated edge runtime or a CDN in front of `/functions/v1`).
  final String? functionBaseUrl;

  /// Killed for debugging push storms; the app then polls on focus instead.
  final bool enableRealtime;

  /// Only set after the hosted Supabase custom:telegram OIDC provider is enabled
  /// and a real Telegram login has passed the hosted callback round trip.
  final bool telegramOidcEnabled;

  /// Public web app URL. The Vercel site is hosted at the domain root
  /// (https://officialmessengerx.vercel.app/), not under a /massanger/ prefix.
  /// Auth redirects must match a Supabase redirect allowlist entry.
  final String? webRedirectUrl;

  static const String _undef = 'SUPABASE_URL_NOT_SET';

  /// The build the entry point uses: every value comes from `--dart-define`.
  ///
  /// `flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
  ///   --dart-define=SUPABASE_ANON_KEY=ey...`
  static const AppEnv fromBuild = AppEnv(
    supabaseUrl: String.fromEnvironment('SUPABASE_URL', defaultValue: _undef),
    supabaseAnonKey: String.fromEnvironment('SUPABASE_ANON_KEY'),
    functionBaseUrl: String.fromEnvironment('FUNCTION_BASE_URL'),
    enableRealtime: bool.fromEnvironment('DISABLE_REALTIME') == false,
    telegramOidcEnabled: bool.fromEnvironment('TELEGRAM_OIDC_ENABLED'),
    webRedirectUrl: String.fromEnvironment('WEB_REDIRECT_URL'),
  );

  String get functionsBase {
    final override = functionBaseUrl;
    if (override != null && override.isNotEmpty && override != _undef) return override;
    return supabaseUrl;
  }

  /// Called once at start-up: a mis-provisioned build must fail loudly instead of
  /// producing an app that signs in against the wrong project.
  void validate() {
    if (supabaseUrl.isEmpty || supabaseUrl == _undef) {
      throw StateError(
        'SUPABASE_URL is not set. Pass it with --dart-define=SUPABASE_URL=... '
        '(see docs/runbook.md §2 for local values).',
      );
    }
    if (!supabaseUrl.startsWith('http')) {
      throw StateError('SUPABASE_URL must be an absolute https/http URL, got "$supabaseUrl".');
    }
    if (supabaseAnonKey.isEmpty || supabaseAnonKey == _undef) {
      throw StateError('SUPABASE_ANON_KEY is not set. Pass it with --dart-define=SUPABASE_ANON_KEY=...');
    }
    final redirect = webRedirectUrl;
    if (redirect != null && redirect.isNotEmpty) {
      final uri = Uri.tryParse(redirect);
      if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty ||
          (uri.scheme != 'https' && !(uri.scheme == 'http' && (uri.host == 'localhost' || uri.host == '127.0.0.1'))) ||
          uri.hasQuery || uri.hasFragment) {
        throw StateError('WEB_REDIRECT_URL must be an absolute HTTPS app URL (or localhost for development).');
      }
    }
  }

  Uri functionsPath(String name) => Uri.parse('$functionsBase/functions/v1/$name');

  Uri get realtimeUrl {
    final https = Uri.parse(supabaseUrl);
    final scheme = https.scheme == 'http' ? 'ws' : 'wss';
    final host = https.host;
    // Self-hosted Supabase serves Realtime on the same origin as the API gateway.
    final port = https.hasPort ? ':${https.port}' : '';
    return Uri.parse('$scheme://$host$port/realtime/v1/websocket');
  }
}
