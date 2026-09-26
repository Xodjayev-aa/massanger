/// Web implementation of the browser-notification bridge.
///
/// Flutter's side of the contract is deliberately thin: all of the Web Push
/// surface (`ServiceWorkerRegistration`, `PushManager`, the permission prompt)
/// lives in `web/push/push-client.js`, and this file only calls it and decodes
/// the JSON it returns. Two reasons for that split:
///
///   * a permission prompt must happen inside the user's tap. Every `await`
///     between the tap and `Notification.requestPermission()` is a chance to
///     lose the user gesture that Safari and Firefox require, and the JS call
///     chain is one hop shorter than the Dart one;
///   * crossing rich JS objects through `dart:js_interop` is far more brittle
///     than crossing a string, and this code cannot be run in the test suite,
///     so the boundary is kept as small as it can be.
///
/// Everything that decides *who* may be notified stays in Dart and Postgres.
library;

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';

import 'push_bridge_types.dart';

/// The global the loader in `web/index.html` installs.
@JS('MessengerXPush')
external JSObject? get _pushClient;

@JS('MessengerXPush.status')
external JSPromise<JSString> _status();

@JS('MessengerXPush.enable')
external JSPromise<JSString> _enable(JSString configUrl);

@JS('MessengerXPush.disable')
external JSPromise<JSString> _disable();

@JS('MessengerXPush.sweep')
external JSPromise<JSString> _sweep(JSString configUrl, JSString accessToken);

/// Reading a missing global as a nullable interop type yields null rather than
/// throwing, which is exactly the guard we want for a cached `index.html` that
/// predates `push-client.js`.
bool get _available => _pushClient != null;

Map<String, dynamic> _decode(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) throw const FormatException('push bridge returned a non-object');
  return Map<String, dynamic>.from(decoded);
}

PushBridgeFailure _failure(String? reason) => switch (reason) {
      'unsupported' => PushBridgeFailure.unsupported,
      'insecure' => PushBridgeFailure.insecure,
      'denied' => PushBridgeFailure.denied,
      'not_configured' => PushBridgeFailure.notConfigured,
      _ => PushBridgeFailure.error,
    };

Future<PushBridgeStatus> browserPushStatus() async {
  if (!_available) return PushBridgeStatus.unsupported;
  try {
    final json = _decode((await _status().toDart).toDart);
    return PushBridgeStatus(
      supported: json['supported'] == true,
      permission: (json['permission'] as String?) ?? 'unsupported',
      registered: json['registered'] == true,
      endpoint: json['endpoint'] as String?,
      label: (json['label'] as String?) ?? '',
    );
  } catch (_) {
    // A bridge that cannot answer is a bridge that cannot notify. Never let this
    // break the settings screen.
    return PushBridgeStatus.unsupported;
  }
}

Future<PushBridgeEnableResult> enableBrowserPush(String configUrl) async {
  if (!_available) {
    return const PushBridgeEnableResult.refused(PushBridgeFailure.unsupported);
  }
  try {
    final json = _decode((await _enable(configUrl.toJS).toDart).toDart);
    if (json['ok'] != true) {
      return PushBridgeEnableResult.refused(_failure(json['reason'] as String?));
    }
    final endpoint = json['endpoint'] as String?;
    final p256dh = json['p256dh'] as String?;
    final auth = json['auth'] as String?;
    if (endpoint == null || p256dh == null || auth == null) {
      return const PushBridgeEnableResult.refused(PushBridgeFailure.error);
    }
    return PushBridgeEnableResult.granted(PushBridgeKeys(
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth,
      label: (json['label'] as String?) ?? '',
    ));
  } catch (_) {
    return const PushBridgeEnableResult.refused(PushBridgeFailure.error);
  }
}

/// Ask the server to drain the queue once. Fire and forget: the server decides
/// what may be sent, so the answer here is not actionable and is not read.
Future<void> sweepBrowserPush(String configUrl, String accessToken) async {
  if (!_available) return;
  if (configUrl.isEmpty || accessToken.isEmpty) return;
  try {
    await _sweep(configUrl.toJS, accessToken.toJS).toDart;
  } catch (_) {
    // Unreachable, refused, rate limited, or a deployment with no push keys.
  }
}

Future<String?> disableBrowserPush() async {
  if (!_available) return null;
  try {
    final json = _decode((await _disable().toDart).toDart);
    return json['endpoint'] as String?;
  } catch (_) {
    return null;
  }
}
