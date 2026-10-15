// Suffix is offline.html's SHA256 prefix; refresh it when changing that page.
const CACHE = "homepage-offline-ffdf4f845b1d";
const OFFLINE = "/offline.html";

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE)
    .then((cache) => cache.add(new Request(OFFLINE, { cache: "reload" })))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys
      .filter((key) => key.startsWith("homepage-offline-") && key !== CACHE)
      .map((key) => caches.delete(key))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.mode !== "navigate" || url.origin !== self.location.origin || url.pathname !== "/") return;
  event.respondWith((async () => {
    try {
      const response = await fetch(event.request, {
        cache: "no-store",
        signal: AbortSignal.timeout(1500),
      });
      // The private ingress also returns 404 through the public entrypoint.
      if (!response.ok) throw new Error("Lab unavailable");
      return response;
    } catch {
      return (await caches.open(CACHE)).match(OFFLINE);
    }
  })());
});
