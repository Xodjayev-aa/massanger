/// Native (Android/iOS) no-op bridge.
///
/// Web Push is deliberately a *web* feature here: on a phone the app is a real
/// app and the $0 delivery path is the TDLib bridge's Saved Messages notices,
/// not a browser push service. Reporting `unsupported` keeps the settings screen
/// honest — it hides the browser switch instead of offering one that cannot work.
library;

import 'push_bridge_types.dart';

Future<PushBridgeStatus> browserPushStatus() async => PushBridgeStatus.unsupported;

Future<PushBridgeEnableResult> enableBrowserPush(String configUrl) async =>
    const PushBridgeEnableResult.refused(PushBridgeFailure.unsupported);

/// Nothing to unsubscribe: returns the endpoint that was removed, if any.
Future<String?> disableBrowserPush() async => null;
