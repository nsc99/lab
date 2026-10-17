import assert from "node:assert/strict";
import { test } from "node:test";
import { calendarModel, duration, refresh, restoreCachedActivity, studyDay } from "../cluster/apps/homepage/anki-study.mjs";

function activity(start, count) {
  const first = Date.parse(`${start}T00:00:00Z`);
  const days = Array.from({ length: count }, (_, i) => ({
    date: new Date(first + i * 86_400_000).toISOString().slice(0, 10),
    reviews: i % 5,
    study_time_seconds: i * 6,
  }));
  return { days, study_day: days.at(-1).date };
}

test("duration distinguishes zero from a positive fraction of a minute", () => {
  assert.equal(duration(0), "0 min");
  assert.equal(duration(0.5), "<1 min");
  assert.equal(duration(59.9), "<1 min");
  assert.equal(duration(60), "1 min");
  assert.equal(duration(3660), "1 h 1 min");
});

test("calendar aligns Sunday weeks across leap day and year boundaries", () => {
  const model = calendarModel(activity("2023-12-31", 366));
  assert.equal(model.columns, 53);
  assert.equal(model.cells[0].row, 0);
  assert.equal(model.cells[0].column, 0);
  const leapDay = model.cells.find((cell) => cell.date === "2024-02-29");
  assert.equal(leapDay.row, 4);
  assert.equal(model.today.date, "2024-12-30");
  assert.equal(model.cells.at(-1).row, 1);
});

test("study-day labels stay unchanged across spring and autumn DST", () => {
  for (const start of ["2026-03-26", "2026-10-22"]) {
    const data = activity(start, 7);
    const model = calendarModel(data);
    assert.deepEqual(model.cells.map((cell) => cell.date), data.days.map((day) => day.date));
    assert.deepEqual(model.cells.map((cell) => cell.row), [4, 5, 6, 0, 1, 2, 3]);
  }
});

test("zero days have no intensity and the highest count has maximum intensity", () => {
  const data = activity("2026-10-01", 7);
  const model = calendarModel(data);
  assert.equal(model.studied, 5);
  assert.equal(model.cells[0].level, 0);
  assert.equal(model.cells[1].level, 1);
  assert.equal(model.cells[4].level, 4);
  data.days.forEach((day) => { day.reviews = 0; day.study_time_seconds = 0; });
  assert.equal(calendarModel(data).studied, 0);
  assert.ok(calendarModel(data).cells.every((cell) => cell.level === 0));
});

test("missing or invalid data cannot masquerade as zero study time", () => {
  const data = activity("2026-10-01", 7);
  assert.throws(() => calendarModel({ days: [], study_day: data.study_day }));
  assert.throws(() => calendarModel({ ...data, study_day: "2026-10-08" }));
  data.days[0].study_time_seconds = null;
  assert.throws(() => calendarModel(data));
  data.days[0].study_time_seconds = 0;
  data.days.splice(2, 1);
  assert.throws(() => calendarModel(data));
});

test("cached study days respect collection timezone, rollover and DST", () => {
  const settings = { timezone: "Europe/Berlin", rollover_hour: 4 };
  for (const [instant, expected] of [
    ["2026-10-17T01:59:00Z", "2026-10-16"],
    ["2026-10-17T02:00:00Z", "2026-10-17"],
    ["2026-03-29T01:30:00Z", "2026-03-28"],
    ["2026-03-29T02:00:00Z", "2026-03-29"],
    ["2026-10-25T01:30:00Z", "2026-10-24"],
    ["2026-10-25T03:00:00Z", "2026-10-25"],
  ]) assert.equal(studyDay(settings, new Date(instant)), expected);
});

const CACHE = "homepage-anki-activity";

function snapshot() {
  const settings = { timezone: "Europe/Berlin", rollover_hour: 4 };
  return {
    ...activity(studyDay(settings), 1), ...settings,
    last_successful_sync: new Date().toISOString(), stale: false, sync_ok: true,
  };
}

function panel(t) {
  function element() {
    const classes = new Set();
    return {
      textContent: "", children: [], attributes: {},
      classList: {
        add: (name) => classes.add(name), contains: (name) => classes.has(name),
        toggle: (name, on) => on ? classes.add(name) : classes.delete(name),
      },
      setAttribute(name, value) { this.attributes[name] = value; },
      append(child) { this.children.push(child); },
      replaceChildren(...children) { this.children = children; },
      get firstElementChild() { return this.children[0]; },
    };
  }
  const nodes = Object.fromEntries(["study-time", "summary", "calendar", "status"].map((id) => [id, element()]));
  const saved = new Map();
  globalThis.document = {
    getElementById: (id) => nodes[id], createElementNS: element,
    querySelector: () => nodes.calendar.firstElementChild,
  };
  globalThis.localStorage = {
    getItem: (key) => saved.get(key) ?? null,
    setItem: (key, value) => saved.set(key, value),
  };
  t.after(() => { delete globalThis.document; delete globalThis.localStorage; });
  return { nodes, saved };
}

test("reload renders saved history before a slow refresh, then saves fresh data", async (t) => {
  const { nodes, saved } = panel(t);
  saved.set(CACHE, JSON.stringify(snapshot()));
  restoreCachedActivity();
  assert.equal(nodes["study-time"].textContent, "0 min");
  assert.ok(nodes.status.textContent.startsWith("Last known data"));
  assert.ok(nodes.status.classList.contains("stale"));
  const oldCalendar = nodes.calendar.firstElementChild;
  let finish;
  t.mock.method(globalThis, "fetch", (url, options) => {
    assert.equal(url, "/anki/activity?days=365");
    assert.equal(options.cache, "no-store");
    return new Promise((resolve) => { finish = resolve; });
  });
  const pending = refresh();
  assert.equal(nodes.calendar.firstElementChild, oldCalendar);
  const fresh = snapshot();
  fresh.days[0].study_time_seconds = 600;
  finish(Response.json(fresh));
  await pending;
  assert.equal(nodes["study-time"].textContent, "10 min");
  assert.ok(!nodes.status.classList.contains("stale"));
  assert.deepEqual(JSON.parse(saved.get(CACHE)), fresh);
  nodes.calendar.replaceChildren();
  restoreCachedActivity();
  assert.equal(nodes["study-time"].textContent, "10 min");
});

test("failed, invalid and non-JSON refreshes preserve the last good cache", async (t) => {
  const { nodes, saved } = panel(t);
  const good = JSON.stringify(snapshot());
  saved.set(CACHE, good);
  restoreCachedActivity();
  const calendar = nodes.calendar.firstElementChild;
  for (const response of [
    new Error("offline"), new Response("unavailable", { status: 503 }),
    new Response("<html>login</html>"), Response.json({ error: "not ready" }),
    Response.json({ ...snapshot(), timezone: "invalid" }),
    Response.json({ ...snapshot(), last_successful_sync: "invalid" }),
  ]) {
    const mocked = t.mock.method(globalThis, "fetch", async () => {
      if (response instanceof Error) throw response;
      return response;
    });
    await refresh();
    mocked.mock.restore();
    assert.equal(saved.get(CACHE), good);
    assert.equal(nodes.calendar.firstElementChild, calendar);
    assert.match(nodes.status.textContent, /showing last loaded data/);
  }
});

test("old snapshots retain history without showing yesterday's time as today's", (t) => {
  const { nodes, saved } = panel(t);
  const old = { ...snapshot(), ...activity("2020-01-01", 7) };
  saved.set(CACHE, JSON.stringify(old));
  restoreCachedActivity();
  assert.ok(nodes.calendar.firstElementChild);
  assert.equal(nodes["study-time"].textContent, "—");
  assert.ok(!nodes["study-time"].classList.contains("zero"));
  assert.ok(nodes.status.classList.contains("stale"));
  const cells = nodes.calendar.firstElementChild.children.filter((child) => "data-date" in child.attributes);
  assert.equal(cells.length, 7);
  assert.ok(cells.every((cell) => cell.attributes.class === ""));
});

test("empty or corrupt storage leaves the first snapshot unknown", (t) => {
  const { nodes, saved } = panel(t);
  for (const value of [null, "invalid JSON", '{"days":[]}', JSON.stringify({ ...snapshot(), rollover_hour: 24 })]) {
    saved.set(CACHE, value);
    restoreCachedActivity();
    assert.ok(!nodes.calendar.firstElementChild);
    assert.ok(!nodes["study-time"].classList.contains("zero"));
  }
});

test("blocked browser storage still renders live data", async (t) => {
  const { nodes } = panel(t);
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true, get() { throw new Error("Storage blocked"); },
  });
  restoreCachedActivity();
  t.mock.method(globalThis, "fetch", async () => Response.json(snapshot()));
  await refresh();
  assert.ok(nodes.calendar.firstElementChild);
  assert.equal(nodes["study-time"].textContent, "0 min");
  assert.ok(!nodes.status.classList.contains("stale"));
});
