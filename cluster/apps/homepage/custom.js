// Homepage persists its default dark theme as if it were a user choice.
// Keep our preference separate so "Browser" can follow system changes.
function setupThemePicker() {
  const root = document.documentElement;
  const nativeToggle = document.querySelector("#theme .cursor-pointer");
  if (!nativeToggle || !root.matches(".light, .dark")) return false;

  const browserTheme = window.matchMedia("(prefers-color-scheme: dark)");
  const storageKey = "homepage-theme-preference";
  const picker = document.createElement("label");
  picker.id = "lab-theme-picker";
  picker.append("Theme ");
  const select = document.createElement("select");
  for (const [value, name] of [["system", "Browser"], ["light", "Light"], ["dark", "Dark"]]) {
    select.add(new Option(name, value));
  }
  try {
    select.value = localStorage.getItem(storageKey) || "system";
  } catch { select.value = "system"; }
  picker.append(select);
  document.getElementById("theme").before(picker);

  function applyTheme() {
    const desired = select.value === "system" ? (browserTheme.matches ? "dark" : "light") : select.value;
    if (!root.classList.contains(desired)) {
      // Use Homepage's own handler so its React context, icons and CSS agree.
      document.querySelector("#theme .cursor-pointer").dispatchEvent(new MouseEvent("click", { bubbles: true }));
    }
  }
  select.addEventListener("change", () => {
    try { localStorage.setItem(storageKey, select.value); } catch { /* Still apply without storage. */ }
    applyTheme();
  });
  browserTheme.addEventListener("change", () => { if (select.value === "system") applyTheme(); });
  applyTheme();
  return true;
}

// Homepage loads its native control dynamically after hydration.
if (!setupThemePicker()) {
  const themeObserver = new MutationObserver(() => {
    if (setupThemePicker()) themeObserver.disconnect();
  });
  themeObserver.observe(document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: ["class"],
  });
}

// Offline setup runs after the dashboard has loaded, away from first paint.
function registerOfflinePage() {
  navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).catch(console.error);
}
if (document.readyState === "complete") registerOfflinePage();
else window.addEventListener("load", registerOfflinePage, { once: true });
