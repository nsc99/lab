// Hash offline.html + background.asset together when updating either file.
const CACHE = "homepage-offline-6e4c1162089c";
const OFFLINE = "/offline.html";
const BACKGROUND = "/background.jpeg";
const STATS_CACHE = "homepage-stats";
const STATS_TTL = 60_000;
const updates = new Map();

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE)
    .then((cache) => cache.addAll([OFFLINE, BACKGROUND].map((url) => new Request(url, { cache: "reload" }))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys
      .filter((key) => (key.startsWith("homepage-offline-") && key !== CACHE) || key === STATS_CACHE)
      .map((key) => caches.delete(key))))
    .then(() => self.clients.claim()));
});

function refreshStats(request, cache) {
  if (!updates.has(request.url)) {
    updates.set(request.url, fetch(request, { cache: "no-store" }).then(async (response) => {
      // Never save HTTP errors, login HTML, or JSON error responses.
      if (response.ok && !response.headers.get("Cache-Control")?.includes("no-store")) {
        try {
          const data = await response.clone().json();
          if (data && !data.error) {
            const headers = new Headers(response.headers);
            headers.delete("Content-Encoding");
            headers.delete("Content-Length");
            headers.set("X-Stats-Saved-At", String(Date.now()));
            await cache.put(request, new Response(response.clone().body, { status: response.status, headers }));
          }
        } catch { /* Unavailable storage must not break an online response. */ }
      }
      return response;
    }).finally(() => updates.delete(request.url)));
  }
  return updates.get(request.url).then((response) => response.clone());
}

async function statsResponse(event) {
  const cache = await caches.open(STATS_CACHE).catch(() => null);
  if (!cache) return fetch(event.request);
  const saved = await cache.match(event.request);
  if (saved) {
    if (Date.now() - Number(saved.headers.get("X-Stats-Saved-At")) >= STATS_TTL) {
      event.waitUntil(refreshStats(event.request, cache).catch(() => {}));
    }
    return saved;
  }
  return refreshStats(event.request, cache);
}

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || event.request.method !== "GET") return;
  if (url.pathname === BACKGROUND) {
    event.respondWith(caches.open(CACHE).then(async (cache) => (await cache.match(BACKGROUND)) || fetch(event.request)));
  } else if (/^\/api\/(?:services\/proxy$|kubernetes\/stats\/)/.test(url.pathname)
      && !event.request.headers.has("Authorization")) {
    // Pod status, config, auth and actions stay live. Only stat reads are saved.
    event.respondWith(statsResponse(event));
  } else if (event.request.mode === "navigate" && url.pathname === "/") {
    event.respondWith((async () => {
      try {
        const response = await fetch(event.request, {
          cache: "no-store",
          signal: AbortSignal.timeout(1500),
        });
        if (!response.ok) throw new Error("Lab unavailable");
        return response;
      } catch {
        return (await caches.open(CACHE)).match(OFFLINE);
      }
    })());
  }
});
