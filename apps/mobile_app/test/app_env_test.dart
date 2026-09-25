// A build that points at the wrong project is worse than a build that fails, so
// AppEnv.validate() is the one gate every entry point passes through. These assert the
// failure copy and the URL derivation that Realtime depends on.

import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/core/env.dart';

void main() {
  const configured = AppEnv(
    supabaseUrl: 'https://abcdef12345.supabase.co',
    supabaseAnonKey: 'eyJhbGciOi.mock',
  );

  group('AppEnv', () {
    test('a missing URL is refused with an actionable message', () {
      const broken = AppEnv(supabaseUrl: '', supabaseAnonKey: 'x');
      expect(broken.validate, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('--dart-define=SUPABASE_URL'))));
    });

    test('the placeholder default is treated as missing, not as a host', () {
      const unset = AppEnv(supabaseUrl: 'SUPABASE_URL_NOT_SET', supabaseAnonKey: 'x');
      expect(unset.validate, throwsStateError);
    });

    test('an anon key is required even when the URL is fine', () {
      const noKey = AppEnv(supabaseUrl: 'https://x.supabase.co', supabaseAnonKey: '');
      expect(noKey.validate, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('SUPABASE_ANON_KEY'))));
    });

    test('a relative URL is caught at start-up rather than at first request', () {
      const relative = AppEnv(supabaseUrl: 'abcdef.supabase.co', supabaseAnonKey: 'x');
      expect(relative.validate, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('absolute'))));
    });

    test('the local stack is http and the realtime scheme follows it', () {
      const local = AppEnv(supabaseUrl: 'http://127.0.0.1:54321', supabaseAnonKey: 'x');
      expect(local.realtimeUrl.toString(), 'ws://127.0.0.1:54321/realtime/v1/websocket');
      expect(configured.realtimeUrl.toString(), 'wss://abcdef12345.supabase.co/realtime/v1/websocket');
    });

    test('web OAuth redirects can target the Vercel site root', () {
      const vercel = AppEnv(
        supabaseUrl: 'https://abcdef12345.supabase.co',
        supabaseAnonKey: 'public-key',
        webRedirectUrl: 'https://messengerx-uz.vercel.app/',
      );
      expect(vercel.webRedirectUrl, 'https://messengerx-uz.vercel.app/');
      vercel.validate();
      const invalid = AppEnv(
        supabaseUrl: 'https://abcdef12345.supabase.co',
        supabaseAnonKey: 'public-key',
        webRedirectUrl: 'http://untrusted.test/with?query=secret',
      );
      expect(invalid.validate, throwsStateError);
    });

    test('Telegram OIDC remains off until a hosted callback has been verified', () {
      expect(configured.telegramOidcEnabled, false);
      const verifiedHost = AppEnv(
        supabaseUrl: 'https://abcdef12345.supabase.co',
        supabaseAnonKey: 'public-key',
        telegramOidcEnabled: true,
      );
      expect(verifiedHost.telegramOidcEnabled, true);
    });

    test('functions can be served from another origin without touching the API URL', () {
      const split = AppEnv(
        supabaseUrl: 'https://abcdef12345.supabase.co',
        supabaseAnonKey: 'x',
        functionBaseUrl: 'https://functions.internal.test',
      );
      expect(split.functionsPath('telegram-send').toString(), 'https://functions.internal.test/functions/v1/telegram-send');
      expect(configured.functionsPath('telegram-link').toString(), 'https://abcdef12345.supabase.co/functions/v1/telegram-link');
    });
  });
}
