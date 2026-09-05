"use strict";

// Deliberately no fetch handler or caches: transcripts and API responses stay online-only.
self.addEventListener("install", event => event.waitUntil(self.skipWaiting()));
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));

function sessionUrl(value) {
  try {
    const url = new URL(value, self.location.origin);
    const id = new URLSearchParams(url.hash.slice(1)).get("session");
    if (url.origin === self.location.origin && url.pathname === "/" && id && /^[A-Za-z0-9_-]+$/.test(id)) {
      return `${self.location.origin}/#session=${encodeURIComponent(id)}`;
    }
  } catch { /* Malformed payloads open the safe session list. */ }
  return `${self.location.origin}/`;
}

self.addEventListener("push", event => {
  let payload = {};
  try { payload = event.data?.json() || {}; } catch { /* Use a generic notification. */ }
  const url = sessionUrl(payload.url);
  event.waitUntil(self.registration.showNotification(
    typeof payload.title === "string" ? payload.title : "OMP · Your turn",
    {
      body: typeof payload.body === "string" ? payload.body : "A session is ready for you.",
      icon: "/icon.svg",
      badge: "/icon.svg",
      tag: url,
      data: { url },
    },
  ));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const url = sessionUrl(event.notification.data?.url);
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const sameOrigin = windows.filter(client => new URL(client.url).origin === self.location.origin);
    const target = sameOrigin.find(client => client.url === url) || sameOrigin[0];
    if (target) {
      try {
        const navigated = target.url === url ? target : await target.navigate(url);
        if (navigated) { await navigated.focus(); return; }
      } catch { /* A closed or unloading client may no longer be usable. */ }
    }
    await self.clients.openWindow(url);
  })());
});
