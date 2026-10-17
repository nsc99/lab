const NS = "http://www.w3.org/2000/svg";
const DAY = 86_400_000;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function duration(seconds) {
  if (seconds === 0) return "0 min";
  if (seconds < 60) return "<1 min";
  const minutes = Math.floor(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
}

export function calendarModel(activity) {
  const days = activity.days;
  const today = days.find((day) => day.date === activity.study_day);
  if (!days.length || !today || days.some((day) =>
    !/^\d{4}-\d{2}-\d{2}$/.test(day.date) || !Number.isInteger(day.reviews) || day.reviews < 0 ||
    !Number.isFinite(day.study_time_seconds) || day.study_time_seconds < 0)) {
    throw new Error("Invalid activity data");
  }
  // Anker supplies calendar labels in the collection's timezone and rollover.
  // UTC arithmetic preserves those labels across local DST and timezone changes.
  const first = Date.parse(`${days[0].date}T00:00:00Z`);
  const offset = new Date(first).getUTCDay();
  const peak = Math.max(1, ...days.map((day) => day.reviews));
  const cells = days.map((day, index) => {
    const date = new Date(first + index * DAY);
    if (date.toISOString().slice(0, 10) !== day.date) throw new Error("Nonconsecutive activity dates");
    return {
      ...day,
      column: Math.floor((index + offset) / 7),
      row: (index + offset) % 7,
      month: MONTHS[date.getUTCMonth()],
      monthStart: (index === 0 && date.getUTCDate() <= 10) || date.getUTCDate() === 1,
      level: day.reviews === 0 ? 0 : Math.min(4, Math.ceil(day.reviews / peak * 4)),
    };
  });
  return { today, cells, columns: cells.at(-1).column + 1, studied: days.filter((day) => day.reviews > 0).length };
}

function svgElement(tag, attributes, text) {
  const element = document.createElementNS(NS, tag);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  if (text !== undefined) element.textContent = text;
  return element;
}

export function renderActivity(activity) {
  const model = calendarModel(activity);
  const time = document.getElementById("study-time");
  time.textContent = duration(model.today.study_time_seconds);
  time.classList.toggle("zero", model.today.study_time_seconds === 0);
  document.getElementById("summary").textContent = `${model.studied} days studied in the past year`;
  const svg = svgElement("svg", { viewBox: `0 0 ${32 + model.columns * 14} 116`, role: "img", "aria-labelledby": "grid-title" });
  svg.append(svgElement("title", { id: "grid-title" }, `Anki study activity: ${model.studied} of ${model.cells.length} days studied. Brighter green means more reviews.`));
  for (const [row, label] of [[1, "Mon"], [3, "Wed"], [5, "Fri"]]) {
    svg.append(svgElement("text", { x: 0, y: 28 + row * 14 }, label));
  }
  let previousMonthColumn = -4;
  for (const cell of model.cells) {
    const x = 32 + cell.column * 14;
    if (cell.monthStart && cell.column - previousMonthColumn >= 3 && cell.column < model.columns - 1) {
      svg.append(svgElement("text", { x, y: 10 }, cell.month));
      previousMonthColumn = cell.column;
    }
    const rect = svgElement("rect", {
      x, y: 18 + cell.row * 14, width: 11, height: 11, rx: 2,
      "data-level": cell.level, "data-date": cell.date,
      class: cell.date === activity.study_day ? "today" : "",
    });
    rect.append(svgElement("title", {}, `${cell.date}: ${cell.reviews} reviews · ${duration(cell.study_time_seconds)}`));
    svg.append(rect);
  }
  const calendar = document.getElementById("calendar");
  const firstRender = !calendar.firstElementChild;
  calendar.replaceChildren(svg);
  if (firstRender) calendar.scrollLeft = calendar.scrollWidth;
  const status = document.getElementById("status");
  const synced = new Date(activity.last_successful_sync).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  const stale = activity.stale || !activity.sync_ok;
  status.textContent = `${stale ? "Last known data · " : ""}Synced ${synced}`;
  status.classList.toggle("stale", stale);
  status.title = `Study day ${activity.study_day} · ${activity.timezone} · resets at ${String(activity.rollover_hour).padStart(2, "0")}:00`;
}

async function refresh() {
  try {
    const response = await fetch("/anki/activity?days=365", { cache: "no-store", signal: AbortSignal.timeout(10_000) });
    if (!response.ok) throw new Error("Anker unavailable");
    renderActivity(await response.json());
  } catch {
    // An unavailable snapshot is unknown, never a false zero-study warning.
    const status = document.getElementById("status");
    status.textContent = document.querySelector("#calendar svg")
      ? "Anker unavailable · showing last loaded data"
      : "Study history unavailable";
    status.classList.add("stale");
  }
}

if (typeof document !== "undefined") {
  refresh();
  // Only the visible study panel polls; day rollover is calculated by Anker.
  setInterval(() => { if (!document.hidden) refresh(); }, 60_000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
}
