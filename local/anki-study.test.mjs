import assert from "node:assert/strict";
import { test } from "node:test";
import { calendarModel, duration } from "../cluster/apps/homepage/anki-study.mjs";

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
