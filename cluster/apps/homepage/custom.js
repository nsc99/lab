(() => {
  const hourInBerlin = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Berlin",
    hour: "numeric",
    hourCycle: "h23",
  });
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");

  function updateDetails() {
    const greeting = document.querySelector(".information-widget-greeting");
    if (greeting) {
      let welcome = greeting.querySelector(".lab-welcome");
      if (!welcome) {
        welcome = document.createElement("p");
        welcome.className = "lab-welcome";
        greeting.append(welcome);
        greeting.dataset.enhanced = "true";
      }
      const hour = Number(hourInBerlin.format(new Date()));
      const message = hour >= 5 && hour < 12
        ? "Good morning. Pick up where you left off."
        : hour >= 12 && hour < 17
          ? "Good afternoon. What are we exploring today?"
          : hour >= 17 && hour < 22
            ? "Good evening. Make yourself at home."
            : "Up late? Make yourself at home.";
      if (welcome.textContent !== message) welcome.textContent = message;
    }

    document.querySelectorAll(".services-group").forEach((group) => {
      const heading = group.querySelector("h2");
      const count = group.querySelectorAll(".service").length + " apps";
      if (heading && heading.dataset.count !== count) heading.dataset.count = count;
    });
  }

  // Widgets hydrate asynchronously; keep the greeting and counts in step with
  // React without replacing any application links or their native behavior.
  new MutationObserver(updateDetails).observe(document.getElementById("__next"), {
    childList: true,
    subtree: true,
  });
  updateDetails();
  window.setInterval(updateDetails, 60000);

  let pendingFrame = 0;
  let activeCard;
  let pointerX = 0;
  let pointerY = 0;
  document.addEventListener("pointermove", (event) => {
    if (reducedMotion.matches || !finePointer.matches || event.pointerType === "touch") return;
    activeCard = event.target.closest(".service-card");
    if (!activeCard) return;
    pointerX = event.clientX;
    pointerY = event.clientY;
    if (pendingFrame) return;
    pendingFrame = window.requestAnimationFrame(() => {
      pendingFrame = 0;
      if (!activeCard) return;
      const bounds = activeCard.getBoundingClientRect();
      activeCard.style.setProperty("--pointer-x", (pointerX - bounds.left) + "px");
      activeCard.style.setProperty("--pointer-y", (pointerY - bounds.top) + "px");
    });
  }, { passive: true });
})();
