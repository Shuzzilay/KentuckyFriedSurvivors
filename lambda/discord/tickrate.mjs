// Server tick rate, derived from the counters PZ stamps on every log line:
//
//   LOG  : General      f:538458 st:143,313,152> World saved
//
// `f` is a monotonic simulation-step counter and `st` is milliseconds since
// process start, so the rate between any two log lines is (Δf / Δst). Measured
// over an hour of real traffic this sits at 10.0/sec while the world runs, and
// near zero while PauseEmpty has it paused.
//
// The value of the number is what it rules out. Desync is usually attributed to
// the server failing to keep up with the simulation, so a full 10 Hz during a
// desync report says the simulation is *not* behind and the cause is elsewhere -
// which is the opposite of what population or hardware tuning would fix.
//
// Kept free of AWS imports so the parsing is testable without the SDK.

export const NOMINAL_HZ = 10;

const SAMPLE = /f:(\d+)\s+st:([\d,]+)/;

// Log lines carry no separator inside the numbers we care about, but `st` is
// printed with thousands separators.
const num = (s) => Number(s.replace(/,/g, ""));

export function parseSamples(messages) {
  const out = [];
  for (const m of messages) {
    const hit = SAMPLE.exec(m ?? "");
    if (hit) out.push({ f: num(hit[1]), st: num(hit[2]) });
  }
  return out;
}

// Both counters reset when the JVM restarts, so a window spanning a restart
// would otherwise produce a negative or wildly wrong rate. Anchor on the last
// point where either counter went backwards and measure only from there.
export function measure(samples, { minSpanMs = 30_000 } = {}) {
  if (samples.length < 2) return { hz: null, reason: "not enough log samples" };

  let anchor = samples[0];
  let prev = samples[0];

  for (const s of samples.slice(1)) {
    if (s.f < prev.f || s.st < prev.st) anchor = s;
    prev = s;
  }

  const spanMs = prev.st - anchor.st;
  const steps = prev.f - anchor.f;

  if (spanMs < minSpanMs) {
    return { hz: null, reason: "server restarted too recently to measure" };
  }

  return { hz: (steps * 1000) / spanMs, spanMs };
}

const fmtSpan = (ms) => {
  const mins = Math.round(ms / 60_000);
  return mins >= 1 ? `${mins}m` : `${Math.round(ms / 1000)}s`;
};

// A paused world is the expected state on an empty server, not a fault, so it
// reads neutral rather than red - PauseEmpty stops the counter on purpose.
export function describeTick({ hz, spanMs, reason }, nominal = NOMINAL_HZ) {
  if (hz === null || hz === undefined) {
    return `⚪ **Tick** no reading - ${reason ?? "no data"}`;
  }

  const shown = hz.toFixed(1);

  if (hz < 0.5) {
    return `⚪ **Tick** ${shown} Hz - world paused (nobody online)`;
  }

  const ratio = hz / nominal;
  const over = ` (${nominal} Hz nominal, over ${fmtSpan(spanMs)})`;

  if (ratio >= 0.95) return `🟢 **Tick** ${shown} Hz${over}`;
  if (ratio >= 0.7) {
    return `🟡 **Tick** ${shown} Hz${over} - simulation falling behind`;
  }
  return `🔴 **Tick** ${shown} Hz${over} - simulation badly behind`;
}
