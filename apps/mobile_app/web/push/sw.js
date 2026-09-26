/*
 * MessengerX push service worker.
 *
 * Served at /push/sw.js, so its scope is /push/ — deliberately *not* the root.
 * Flutter already ships and registers `flutter_service_worker.js` at `/` for
 * offline caching, and two service workers cannot control the same scope. Push
 * does not need to intercept fetches, so giving this one a narrow scope keeps
 * both jobs working without either owning the other.
 *
 * The rule this file must never break: a `push` event MUST show a notification.
 * A subscription created with `userVisibleOnly: true` exists on the promise that
 * every push produces something the user can see, and a browser that catches us
 * silently dropping one is entitled to unsubscribe us. So every path below ends
 * in `showNotification`, including the "we have no idea what this is" path.
 */

/* eslint-env serviceworker */

const FALLBACK = {
  title: 'MessengerX',
  body: 'New message',
  tag: 'messengerx',
};

self.addEventListener('install', () => {
  // A new deploy must be able to take over without waiting for every tab to close:
  // a stale worker that cannot parse the current payload shape shows nothing.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let payload = FALLBACK;
  try {
    // Some push services deliver an empty body for a "tickle"; treat anything
    // unparseable as a generic alert rather than as an error.
    const data = event.data ? event.data.json() : null;
    if (data && typeof data === 'object') payload = data;
  } catch (_) {
    payload = FALLBACK;
  }

  const title = typeof payload.title === 'string' && payload.title.length > 0 ? payload.title : FALLBACK.title;
  const body = typeof payload.body === 'string' ? payload.body : FALLBACK.body;
  const tag = typeof payload.tag === 'string' && payload.tag.length > 0 ? payload.tag : FALLBACK.tag;
  const data = payload.data && typeof payload.data === 'object' ? payload.data : {};

  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      tag,
      // Replacing a notification with the same tag must still buzz: a folded
      // chat stack is new information, not a redraw.
      renotify: true,
      icon: '/icons/icon-192.png',
      badge: '/icons/icon-192.png',
      // The same tag names the chat, so a burst collapses into one line.
      data,
      requireInteraction: false,
      silent: false,
    }),
  );
});

/**
 * The browser rotated or dropped the subscription behind our back (common on
 * iOS, and after a long offline period). Only the page can re-register — it has
 * the session and the Supabase client — so tell any open tab and let the app do
 * it. Nothing here can authenticate.
 */
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        client.postMessage({ type: 'messengerx:push-subscription-changed' });
      }
    }),
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const data = event.notification.data || {};
  // Absolute path, relative to this origin — `/chats/<id>` under the path URL
  // strategy the web build uses.
  const target = typeof data.url === 'string' && data.url.startsWith('/') ? data.url : '/chats';
  const url = new URL(target, self.location.origin).toString();

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      // Prefer the tab the user already has: a notification tap should not
      // scatter a second copy of the app across their window list.
      for (const client of clients) {
        if (!client.url.startsWith(self.location.origin)) continue;
        return client
          .focus()
          .then((focused) => {
            // `navigate` is not implemented everywhere; focusing the existing
            // tab is still a better outcome than opening a duplicate.
            if (focused && typeof focused.navigate === 'function') {
              return focused.navigate(url).catch(() => undefined);
            }
            if (typeof focused?.postMessage === 'function') {
              focused.postMessage({ type: 'messengerx:open-chat', url: target });
            }
            return undefined;
          })
          .catch(() => self.clients.openWindow(url));
      }
      return self.clients.openWindow(url);
    }),
  );
});
