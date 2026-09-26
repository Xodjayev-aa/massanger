/*
 * MessengerX push client.
 *
 * The browser side of the notification switch. Flutter calls into this through
 * a tiny `window.MessengerXPush` surface and reads JSON strings back, for one
 * practical reason: every Web Push API lives on `window`, and `dart:js_interop`
 * crossing of rich objects and Promises is far more fragile than passing a
 * string. Keeping the whole flow in one language also means there is exactly one
 * place where a browser API is called.
 *
 * What this file does NOT do: talk to Supabase. It returns the subscription the
 * browser generated, and Dart stores it through the
 * `register_push_subscription` RPC, so Postgres RLS and the session stay the
 * single authority for who owns what. The one exception is fetching the public
 * VAPID key, which is an unauthenticated GET of public information.
 *
 * Nothing here runs until the user asks for notifications: registering a push
 * service worker or prompting for permission on page load is exactly the
 * behaviour that trains people to block the prompt.
 */
(function () {
  'use strict';

  var SW_URL = '/push/sw.js';
  var SW_SCOPE = '/push/';

  function supported() {
    return typeof window !== 'undefined' &&
      'serviceWorker' in navigator &&
      'PushManager' in window &&
      'Notification' in window &&
      window.isSecureContext === true;
  }

  /** base64url (no padding) for the keys the Push API hands back as buffers. */
  function toBase64Url(buffer) {
    var bytes = new Uint8Array(buffer);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  /** The VAPID public key travels as base64url; the Push API wants the bytes. */
  function fromBase64Url(value) {
    var padded = value.replace(/-/g, '+').replace(/_/g, '/');
    while (padded.length % 4 !== 0) padded += '=';
    var binary = atob(padded);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  /**
   * Short, human label for the device list ("Chrome · Android"). Deliberately
   * coarse: the point is for the user to recognise their own browser, not to
   * fingerprint it.
   */
  function deviceLabel() {
    var ua = navigator.userAgent || '';
    var browser = /Edg\//.test(ua) ? 'Edge'
      : /OPR\//.test(ua) ? 'Opera'
      : /Firefox\//.test(ua) ? 'Firefox'
      : /CriOS|Chrome\//.test(ua) ? 'Chrome'
      : /Safari\//.test(ua) ? 'Safari'
      : 'Browser';
    var platform = /Android/.test(ua) ? 'Android'
      : /iPhone|iPad|iPod/.test(ua) ? 'iOS'
      : /Mac OS X/.test(ua) ? 'macOS'
      : /Windows/.test(ua) ? 'Windows'
      : /Linux/.test(ua) ? 'Linux'
      : '';
    return platform ? browser + ' · ' + platform : browser;
  }

  function currentSubscriptionEndpoint() {
    if (!supported()) return Promise.resolve(null);
    return navigator.serviceWorker
      .getRegistration(SW_SCOPE)
      .then(function (registration) {
        return registration ? registration.pushManager.getSubscription() : null;
      })
      .then(function (subscription) {
        return subscription ? subscription.endpoint : null;
      })
      .catch(function () {
        return null;
      });
  }

  /** `{ supported, permission, registered, endpoint }` as JSON. */
  function status() {
    var payload = {
      supported: supported(),
      permission: supported() ? Notification.permission : 'unsupported',
      registered: false,
      endpoint: null,
      label: supported() ? deviceLabel() : '',
    };
    if (!payload.supported) return Promise.resolve(JSON.stringify(payload));
    return navigator.serviceWorker
      .getRegistration(SW_SCOPE)
      .then(function (registration) {
        return registration ? registration.pushManager.getSubscription() : null;
      })
      .then(function (subscription) {
        payload.registered = !!subscription;
        payload.endpoint = subscription ? subscription.endpoint : null;
        return JSON.stringify(payload);
      })
      .catch(function () {
        return JSON.stringify(payload);
      });
  }

  function ensureRegistration() {
    return navigator.serviceWorker.register(SW_URL, {
      scope: SW_SCOPE,
      // Always revalidate the worker script: a stale worker cannot parse a new
      // payload shape, and "shows nothing" is the worst possible failure.
      updateViaCache: 'none',
    }).then(function () {
      return navigator.serviceWorker.ready;
    });
  }

  /**
   * Ask for permission, subscribe, and hand the keys back to Dart.
   *
   * Must be called from a user gesture — Safari and Firefox both refuse a
   * permission request from a promise chain that is no longer user-initiated.
   */
  function enable(configUrl) {
    if (!supported()) {
      return Promise.resolve(JSON.stringify({
        ok: false,
        reason: window.isSecureContext === false ? 'insecure' : 'unsupported',
      }));
    }

    var existing = null;
    return navigator.serviceWorker
      .getRegistration(SW_SCOPE)
      .then(function (registration) {
        return registration ? registration.pushManager.getSubscription() : null;
      })
      .catch(function () {
        return null;
      })
      .then(function (subscription) {
        existing = subscription;
        if (existing) return Notification.permission;
        return Notification.requestPermission();
      })
      .then(function (permission) {
        if (permission !== 'granted') {
          return JSON.stringify({ ok: false, reason: 'denied', permission: permission });
        }
        return fetch(configUrl, { method: 'GET', headers: { accept: 'application/json' }, cache: 'no-store' })
          .then(function (response) {
            if (!response.ok) throw new Error('config HTTP ' + response.status);
            return response.json();
          })
          .then(function (body) {
            var key = body && body.ok && body.data ? body.data.vapid_public_key : null;
            if (!key) {
              // The deployment has no VAPID identity: say so instead of
              // subscribing to something we could never deliver to.
              return JSON.stringify({ ok: false, reason: 'not_configured' });
            }
            if (existing) return { key: key, subscription: existing };
            return ensureRegistration()
              .then(function (registration) {
                return registration.pushManager.subscribe({
                  // Required, and honest: we only ever push to show a notification.
                  userVisibleOnly: true,
                  applicationServerKey: fromBase64Url(key),
                });
              })
              .then(function (subscription) {
                return { key: key, subscription: subscription };
              });
          })
          .then(function (result) {
            var subscription = result.subscription;
            var json = subscription.toJSON();
            return JSON.stringify({
              ok: true,
              endpoint: subscription.endpoint,
              p256dh: json.keys && json.keys.p256dh ? json.keys.p256dh : toBase64Url(subscription.getKey('p256dh')),
              auth: json.keys && json.keys.auth ? json.keys.auth : toBase64Url(subscription.getKey('auth')),
              label: deviceLabel(),
            });
          });
      })
      .catch(function (error) {
        return JSON.stringify({ ok: false, reason: 'error', message: String(error && error.message ? error.message : error) });
      });
  }

  /**
   * Drop this browser's subscription. Returns the endpoint it removed so Dart
   * can delete the matching row — the subscription is dead either way once the
   * browser forgets it, and leaving the row would waste a device slot.
   */
  function disable() {
    if (!supported()) return Promise.resolve(JSON.stringify({ ok: true, endpoint: null }));
    return navigator.serviceWorker
      .getRegistration(SW_SCOPE)
      .then(function (registration) {
        return registration ? registration.pushManager.getSubscription() : null;
      })
      .then(function (subscription) {
        if (!subscription) return JSON.stringify({ ok: true, endpoint: null });
        var endpoint = subscription.endpoint;
        return subscription.unsubscribe().then(function () {
          return JSON.stringify({ ok: true, endpoint: endpoint });
        });
      })
      .catch(function (error) {
        return JSON.stringify({ ok: false, reason: 'error', message: String(error && error.message ? error.message : error) });
      });
  }

  /**
   * Ask the server to drain the notification queue once.
   *
   * No server of ours polls for work, so whichever app is already awake keeps
   * the queue moving. It rides the presence heartbeat, so this is best effort by
   * design: `web_push_claim` decides what may be sent, and a sweep that is lost,
   * refused or run twice costs at most a delay. `keepalive` lets it finish even
   * if the tab is being closed, and every outcome is swallowed — nothing here is
   * something the person using the app can act on.
   */
  function sweep(configUrl, accessToken) {
    if (!configUrl || !accessToken) {
      return Promise.resolve(JSON.stringify({ ok: false, reason: 'skipped' }));
    }
    return fetch(configUrl, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: 'Bearer ' + accessToken,
      },
      body: JSON.stringify({ limit: 5 }),
      keepalive: true,
      cache: 'no-store',
    }).then(function (response) {
      return JSON.stringify({ ok: response.ok, status: response.status });
    }).catch(function () {
      return JSON.stringify({ ok: false, reason: 'unreachable' });
    });
  }

  window.MessengerXPush = {
    status: status,
    enable: enable,
    disable: disable,
    sweep: sweep,
    /** Exposed for the app to match a stored row against this browser. */
    deviceLabel: deviceLabel,
  };
})();
