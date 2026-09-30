import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/account_repository.dart';
import '../data/bot_repository.dart';
import '../data/chat_repository.dart';
import '../data/community_repository.dart';
import '../data/economy_repository.dart';
import '../data/feed_repository.dart';
import '../data/media_cache.dart';
import '../data/push_repository.dart';
import '../data/shorts_repository.dart';
import '../data/social_repository.dart';
import '../data/telegram_repository.dart';
import '../data/video_repository.dart';
import '../data/voice_over.dart';
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
    ..registerLazySingleton<AccountRepository>(
      () => AccountRepository(
        client,
        telegramLoginEnabled: env.telegramOidcEnabled,
        webRedirectUrl: env.webRedirectUrl,
      ),
    )
    // The B2 ticket office is shared: the chat upload path, the bubble's
    // signed-URL cache and the shorts publisher all speak to `video-ticket`
    // through this one instance.
    ..registerLazySingleton<VideoRepository>(() => VideoRepository(client))
    ..registerLazySingleton<ChatRepository>(() => ChatRepository(client, videos: sl<VideoRepository>()))
    ..registerLazySingleton<ShortsRepository>(() => ShortsRepository(client, sl<VideoRepository>()))
    ..registerLazySingleton<TelegramRepository>(() => TelegramRepository(client))
    // Browser notifications read their VAPID key from the public `web-push-send`
    // function, so the URL comes from the same build configuration as every
    // other function call rather than from a hard-coded host.
    ..registerLazySingleton<PushRepository>(
      () => PushRepository(client, pushConfigUrl: env.functionsPath('web-push-send').toString()),
    )
    // The feed side of the product: the video graph (00021), the social graph
    // (00020), the economy (00025), communities (00023) and the bot platform
    // (00026). Each is a thin RPC client over its own migration.
    ..registerLazySingleton<FeedRepository>(() => FeedRepository(client))
    ..registerLazySingleton<SocialRepository>(() => SocialRepository(client))
    ..registerLazySingleton<EconomyRepository>(() => EconomyRepository(client))
    ..registerLazySingleton<CommunityRepository>(() => CommunityRepository(client))
    ..registerLazySingleton<BotRepository>(() => BotRepository(client))
    // Signed URLs live behind one cache so a poster, a bubble and a reel that
    // point at the same key share a single presign.
    ..registerLazySingleton<MediaCache>(() => MediaCache(sl<VideoRepository>()))
    ..registerLazySingleton<VoiceOverService>(VoiceOverService.new)
    ..registerLazySingleton<VoiceService>(VoiceService.new)
    ..registerLazySingleton<VoicePlayer>(VoicePlayer.new);
}

/// Called from `AppLifecycleListener`-style hooks in [MessengerXApp]; keeping the
/// teardown in one place stops a dispose from being forgotten when a provider moves
/// up the tree.
Future<void> disposeDependencies() async {
  if (sl.isRegistered<VoiceService>()) await sl<VoiceService>().dispose();
  if (sl.isRegistered<VoicePlayer>()) await sl<VoicePlayer>().dispose();
  if (sl.isRegistered<VoiceOverService>()) sl<VoiceOverService>().dispose();
  await sl.reset();
}
