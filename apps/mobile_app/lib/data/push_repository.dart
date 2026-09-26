import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/errors.dart';
import 'push_bridge.dart';

/// One registered browser, as the settings screen shows it.
class PushDevice {
  const PushDevice({required this.id, required this.endpoint, required this.label, this.lastSuccessAt});

  final String id;
  final String endpoint;
  final String label;
  final DateTime? lastSuccessAt;
}

/// Everything the browser-notification switch needs, resolved once.
class BrowserPushState {
  const BrowserPushState({
    required this.bridge,
    required this.enabled,
    required this.devices,
    required this.thisBrowserEndpoint,
    this.serverReadable = true,
  });

  /// What the browser itself says: supported, permission, whether it holds a
  /// subscription right now.
  final PushBridgeStatus bridge;

  /// `profiles.push_web` — the server-side preference that gates queueing.
  final bool enabled;

  final List<PushDevice> devices;

  /// This browser's live endpoint, when it has one.
  final String? thisBrowserEndpoint;

  /// True when the server still has a row for the browser holding this session.
  /// A browser can hold a subscription the server has already deleted (the user
  /// removed it, or the push service answered 404), and that mismatch is exactly
  /// what makes the switch look "on" while nothing arrives.
  bool get thisBrowserRegistered =>
      thisBrowserEndpoint != null && devices.any((device) => device.endpoint == thisBrowserEndpoint);

  /// The browser could not be told where the notification settings live. The
  /// switch is hidden rather than shown broken.
  final bool serverReadable;

  /// Nothing to show: a native build, a browser without the Push API, or a
  /// deployment whose database has not been migrated yet.
  bool get unavailable => !bridge.supported || !serverReadable;

  bool get blocked => bridge.blocked;
}

/// Browser notifications: the switch, the device list, and the browser's own
/// subscription.
///
/// The split of responsibility is the point of this class. The *browser* owns
/// the subscription (it generated the keys and it can revoke them), and the
/// *database* owns the decision to notify (`profiles.push_web`) plus the list of
/// endpoints worth sending to. Neither half is trusted with the other's job:
///
///   * turning the switch on subscribes in the browser and then stores what the
///     browser produced, through an RPC that validates its shape and enforces
///     the per-user device cap;
///   * turning it off writes the preference through `set_web_push_enabled`,
///     which cancels queued notices in the same transaction — so "off" cannot
///     lose a race with a notification that is already in the queue;
///   * removing a browser unsubscribes it *and* deletes its row, so a device
///     slot is genuinely freed rather than hidden.
class PushRepository {
  PushRepository(this._client, {required String pushConfigUrl}) : _pushConfigUrl = pushConfigUrl;

  final SupabaseClient _client;

  /// The public `web-push` function URL, which serves the VAPID public key.
  /// Passed in rather than read from a global so a test can point it anywhere.
  final String _pushConfigUrl;

  String _currentUid() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const AppException('auth', 'Sign in to manage notifications.');
    }
    return user.id;
  }

  /// Reads the browser and the server. Never throws: this runs as one branch of
  /// the settings screen's load, and a deployment that has not applied the
  /// browser-push migration yet must lose a switch, not the whole screen.
  Future<BrowserPushState> load() async {
    final bridge = await browserPushStatus();
    if (bridge.unsupported) {
      return BrowserPushState(
        bridge: bridge,
        enabled: false,
        devices: const <PushDevice>[],
        thisBrowserEndpoint: null,
      );
    }
    try {
      final uid = _currentUid();
      final profile = await _client.from('profiles').select('push_web').eq('id', uid).maybeSingle();
      final rows = await _client
          .from('push_subscriptions')
          .select('id, endpoint, label, last_success_at')
          .eq('user_id', uid)
          // `filter(...)` rather than the `isFilter` alias: the same builder
          // method has existed since the first postgrest-dart release, and this
          // file has to compile against the whole pinned supabase_flutter range.
          .filter('disabled_at', 'is', null)
          .order('created_at', ascending: true);
      return BrowserPushState(
        bridge: bridge,
        enabled: profile?['push_web'] == true,
        devices: rows.map(_device).toList(growable: false),
        thisBrowserEndpoint: bridge.endpoint,
      );
    } catch (_) {
      return BrowserPushState(
        bridge: bridge,
        enabled: false,
        devices: const <PushDevice>[],
        thisBrowserEndpoint: bridge.endpoint,
        serverReadable: false,
      );
    }
  }

  /// Subscribe this browser, store it, and turn the preference on.
  ///
  /// Called from the switch's tap so the permission prompt is still inside the
  /// user gesture. Every failure is a *typed* reason rather than an exception:
  /// a blocked browser and a deployment without push keys both need different
  /// words on screen, and neither is a crash.
  Future<BrowserPushState> turnOn() async {
    final result = await enableBrowserPush(_pushConfigUrl);
    final keys = result.keys;
    if (keys == null) {
      final failure = result.failure ?? PushBridgeFailure.error;
      throw AppException('push_${failure.name}', failure.message);
    }

    try {
      await _client.rpc<dynamic>('register_push_subscription', params: <String, Object?>{
        'p_endpoint': keys.endpoint,
        'p_p256dh': keys.p256dh,
        'p_auth': keys.auth,
        'p_label': keys.label,
      });
      await _client.rpc<dynamic>('set_web_push_enabled', params: <String, Object?>{'p_enabled': true});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
    return load();
  }

  /// Stop sending browser notifications. Keeps this browser's row so turning the
  /// switch back on is instant, and cancels anything already queued server-side.
  Future<BrowserPushState> turnOff() async {
    try {
      await _client.rpc<dynamic>('set_web_push_enabled', params: <String, Object?>{'p_enabled': false});
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
    return load();
  }

  /// Drain the browser-notification queue once, best effort.
  ///
  /// This is a latency mechanism, never a correctness one: `web_push_claim`
  /// alone decides what may be sent, so a sweep that is lost, refused or run
  /// twice costs at most a delay. It rides the presence heartbeat, which is
  /// already throttled and already only fires while the app is foregrounded, so
  /// whichever app happens to be open keeps the queue moving with no scheduler
  /// for the operator to configure. A deployment that also wires the documented
  /// database webhook gets immediate delivery instead.
  Future<void> sweep() async {
    try {
      // `functions.invoke` builds the URL from the Supabase origin. A build that
      // overrides FUNCTION_BASE_URL would need the URL posted by hand; nothing in
      // the app does that today, and a missed sweep is harmless by design.
      await _client.functions.invoke('web-push', body: const <String, Object?>{'limit': 5});
    } catch (_) {
      // Missing function, missing VAPID keys, rate limit, offline: none of these
      // are things the person using the app can act on, and none of them mean a
      // notification was lost.
    }
  }

  /// Forget this browser entirely: revoke the subscription and drop its row.
  Future<BrowserPushState> forgetThisBrowser() async {
    try {
      final uid = _currentUid();
      final endpoint = await disableBrowserPush();
      if (endpoint != null) {
        await _client.from('push_subscriptions').delete().eq('user_id', uid).eq('endpoint', endpoint);
      }
    } catch (error, stack) {
      throw AppException.wrap(error, stack);
    }
    return load();
  }

  static PushDevice _device(Map<String, dynamic> row) => PushDevice(
        id: row['id'] as String,
        endpoint: row['endpoint'] as String,
        label: (row['label'] as String?)?.trim().isNotEmpty == true ? row['label'] as String : 'Browser',
        lastSuccessAt: row['last_success_at'] == null ? null : DateTime.tryParse('${row['last_success_at']}'),
      );
}
