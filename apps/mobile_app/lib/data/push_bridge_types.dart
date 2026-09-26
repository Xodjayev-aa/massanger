/// Shared vocabulary for the browser-notification bridge.
///
/// The browser half lives in `web/push/push-client.js`; these are the values it
/// reports back, decoded. Kept in their own file so the stub (Android/iOS) and
/// the web implementation agree on the shape without either importing the other.
library;

/// Whether this build can raise a browser notification at all, and what the
/// browser currently thinks about it.
class PushBridgeStatus {
  const PushBridgeStatus({
    required this.supported,
    required this.permission,
    required this.registered,
    this.endpoint,
    this.label = '',
  });

  /// False on Android/iOS and on any browser without the Push API.
  final bool supported;

  /// `'granted'`, `'denied'`, `'default'` or `'unsupported'`.
  final String permission;

  /// True when *this* browser holds a push subscription. It says nothing about
  /// whether the server still has the matching row — the app compares
  /// [endpoint] against its own device list for that.
  final bool registered;

  final String? endpoint;

  /// Coarse device label ("Chrome · Android") for the device list.
  final String label;

  bool get blocked => permission == 'denied';
  bool get canAsk => supported && permission == 'default';

  static const PushBridgeStatus unsupported = PushBridgeStatus(
    supported: false,
    permission: 'unsupported',
    registered: false,
  );
}

/// The subscription a browser generated, on its way to `push_subscriptions`.
class PushBridgeKeys {
  const PushBridgeKeys({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
    this.label = '',
  });

  final String endpoint;
  final String p256dh;
  final String auth;
  final String label;
}

/// Why an attempt to enable browser notifications did not produce a subscription.
enum PushBridgeFailure {
  unsupported,
  insecure,
  denied,
  notConfigured,
  error,
}

extension PushBridgeFailureMessage on PushBridgeFailure {
  /// Phrased for the person looking at the screen, not for a log line.
  String get message => switch (this) {
        PushBridgeFailure.unsupported =>
          'This browser cannot show notifications. On an iPhone, add MessengerX to your Home Screen first.',
        PushBridgeFailure.insecure =>
          'Notifications need an HTTPS address. Open the site over https and try again.',
        PushBridgeFailure.denied =>
          'Notifications are blocked for this site. Allow them in your browser settings, then try again.',
        PushBridgeFailure.notConfigured =>
          'This MessengerX deployment has not been given push keys yet, so it cannot send notifications.',
        PushBridgeFailure.error => 'Could not turn on notifications. Try again.',
      };
}

/// Result of an enable attempt: keys, or a reason.
class PushBridgeEnableResult {
  const PushBridgeEnableResult.granted(PushBridgeKeys this.keys) : failure = null;
  const PushBridgeEnableResult.refused(PushBridgeFailure this.failure) : keys = null;

  final PushBridgeKeys? keys;
  final PushBridgeFailure? failure;

  bool get ok => keys != null;
}
