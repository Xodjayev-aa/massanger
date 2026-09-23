import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/account_repository.dart';
import '../data/chat_repository.dart';
import '../data/telegram_repository.dart';
import '../data/voice_service.dart';

/// Composition root.
///
/// Repositories are registered as singletons because they hold caches (signed URLs,
/// the realtime channels) and the app is meant to have exactly one of each per
/// Supabase client. Blocs are *not* registered here: they are created by the widget
/// tree so their lifetime follows the screen they serve.
GetIt sl = GetIt.instance;

void registerDependencies({required AppEnv env, required SupabaseClient client}) {
  sl
    ..registerLazySingleton<AppEnv>(() => env)
    ..registerLazySingleton<SupabaseClient>(() => client)
    ..registerLazySingleton<AccountRepository>(() => AccountRepository(client))
    ..registerLazySingleton<ChatRepository>(() => ChatRepository(client))
    ..registerLazySingleton<TelegramRepository>(() => TelegramRepository(client))
    ..registerLazySingleton<VoiceService>(VoiceService.new)
    ..registerLazySingleton<VoicePlayer>(VoicePlayer.new);
}

/// Called from `AppLifecycleListener`-style hooks in [MessengerXApp]; keeping the
/// teardown in one place stops a dispose from being forgotten when a provider moves
/// up the tree.
Future<void> disposeDependencies() async {
  if (sl.isRegistered<VoiceService>()) await sl<VoiceService>().dispose();
  if (sl.isRegistered<VoicePlayer>()) await sl<VoicePlayer>().dispose();
  await sl.reset();
}
