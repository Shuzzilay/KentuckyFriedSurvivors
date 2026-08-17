// node --test lambda/discord/
//
// Log lines are copied from the real /ecs/pz stream, including the two shapes
// the counters appear in (the `st:...>` form and the `st:... at Class.method`
// form), because the parser has to match both.

import test from "node:test";
import assert from "node:assert/strict";
import { parseSamples, measure, describeTick } from "./tickrate.mjs";

const REAL_LINES = [
  "LOG  : General      f:538458 st:143,313,152> World saved",
  "WARN : Packet       f:538470 st:143,314,352 at PacketsCache.<init>  > No packet handler",
  "LOG  : Network      f:538558 st:143,323,152> Connected new client 1 ID # 0",
];

test("parses both log line shapes", () => {
  assert.deepEqual(parseSamples(REAL_LINES), [
    { f: 538458, st: 143313152 },
    { f: 538470, st: 143314352 },
    { f: 538558, st: 143323152 },
  ]);
});

test("ignores lines without the counters", () => {
  const lines = ["[backup] uploaded pz-x.tar.gz (81M)", "[entrypoint] Issuing quit."];
  assert.deepEqual(parseSamples(lines), []);
});

test("measures 10 Hz from a clean run", () => {
  // 6000 steps over 600s.
  const samples = [
    { f: 1000, st: 1_000_000 },
    { f: 4000, st: 1_300_000 },
    { f: 7000, st: 1_600_000 },
  ];
  const { hz } = measure(samples);
  assert.ok(Math.abs(hz - 10) < 0.001, `expected ~10, got ${hz}`);
});

test("a degraded server reads below nominal", () => {
  const { hz } = measure([
    { f: 0, st: 0 },
    { f: 3000, st: 600_000 },
  ]);
  assert.equal(hz, 5);
});

test("anchors after a restart rather than spanning it", () => {
  // Counters reset midway; spanning the reset would give a negative rate.
  const samples = [
    { f: 500_000, st: 9_000_000 },
    { f: 503_000, st: 9_300_000 },
    { f: 2, st: 40_000 }, // restart
    { f: 3002, st: 340_000 },
  ];
  const { hz } = measure(samples);
  assert.ok(Math.abs(hz - 10) < 0.001, `expected ~10 after restart, got ${hz}`);
});

test("refuses to measure across too short a span", () => {
  const { hz, reason } = measure([
    { f: 0, st: 0 },
    { f: 50, st: 5_000 },
  ]);
  assert.equal(hz, null);
  assert.match(reason, /restarted too recently/);
});

test("refuses to measure with a single sample", () => {
  const { hz, reason } = measure([{ f: 1, st: 1000 }]);
  assert.equal(hz, null);
  assert.match(reason, /not enough/);
});

test("a paused world reads neutral, not red", () => {
  const line = describeTick({ hz: 0.07, spanMs: 3_600_000 });
  assert.match(line, /⚪/);
  assert.match(line, /world paused/);
});

test("healthy, degraded and bad tick rates get distinct icons", () => {
  const span = { spanMs: 600_000 };
  assert.match(describeTick({ hz: 10.0, ...span }), /🟢/);
  assert.match(describeTick({ hz: 8.0, ...span }), /🟡/);
  assert.match(describeTick({ hz: 8.0, ...span }), /falling behind/);
  assert.match(describeTick({ hz: 3.0, ...span }), /🔴/);
});

test("renders the nominal and the window", () => {
  const line = describeTick({ hz: 9.9, spanMs: 600_000 });
  assert.equal(line, "🟢 **Tick** 9.9 Hz (10 Hz nominal, over 10m)");
});

test("a missing reading explains itself", () => {
  const line = describeTick({ hz: null, reason: "not enough log samples" });
  assert.match(line, /⚪/);
  assert.match(line, /not enough log samples/);
});
