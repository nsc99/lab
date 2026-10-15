// Offline setup runs after the dashboard has loaded, away from first paint.
function registerOfflinePage() {
  navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).catch(console.error);
}
if (document.readyState === "complete") registerOfflinePage();
else window.addEventListener("load", registerOfflinePage, { once: true });
