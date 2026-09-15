import { describe, expect, test } from "bun:test";
import { parseClaudeUsage, parseCodexUsage } from "../src/providers";

const now = new Date("2026-09-15T16:00:00Z");

describe("Codex /wham/usage", () => {
  test("classifies the five-hour and weekly windows by their length", () => {
    const usage = parseCodexUsage(
      {
        plan_type: "plus",
        rate_limit: {
          allowed: false,
          limit_reached: true,
          primary_window: { used_percent: 100, limit_window_seconds: 18000, reset_after_seconds: 7492, reset_at: 1789498080 },
          secondary_window: { used_percent: 78, limit_window_seconds: 604800, reset_after_seconds: 315694, reset_at: 1789806282 },
        },
      },
      now,
    );
    expect(usage.session).toEqual({ usedPercent: 100, resetsAt: new Date(1789498080 * 1000).toISOString() });
    expect(usage.weekly).toEqual({ usedPercent: 78, resetsAt: new Date(1789806282 * 1000).toISOString() });
    expect(usage.fetchedAt).toBe(now.toISOString());
    expect(usage.note).toBeNull();
  });

  test("a lone long window counts as weekly and a missing rate limit is noted", () => {
    const lone = parseCodexUsage({ rate_limit: { primary_window: { used_percent: 5, limit_window_seconds: 604800 } } }, now);
    expect(lone.session).toBeNull();
    expect(lone.weekly?.usedPercent).toBe(5);
    expect(lone.weekly?.resetsAt).toBeNull();
    const none = parseCodexUsage({ plan_type: "free" }, now);
    expect(none.session).toBeNull();
    expect(none.note).toContain("did not report");
  });
});

describe("Claude /api/oauth/usage", () => {
  test("keeps utilization as percent used, normalizes reset timestamps, and lifts per-model weekly buckets", () => {
    const usage = parseClaudeUsage(
      {
        five_hour: { utilization: 12.5, resets_at: "2026-09-15T20:00:00.000000+00:00" },
        seven_day: { utilization: 51, resets_at: "2026-09-18T07:00:00.154362+00:00" },
        limits: [
          { kind: "session", group: "session", percent: 12, resets_at: "2026-09-15T20:00:00.000000+00:00", scope: null },
          { kind: "weekly_all", group: "weekly", percent: 51, resets_at: "2026-09-18T07:00:00.154362+00:00", scope: null },
          { kind: "weekly_scoped", group: "weekly", percent: 8, resets_at: "2026-09-18T07:00:00.726981+00:00", scope: { model: { id: null, display_name: "Fable" }, surface: null } },
        ],
      },
      now,
    );
    expect(usage.session).toEqual({ usedPercent: 12.5, resetsAt: "2026-09-15T20:00:00.000Z" });
    expect(usage.weekly).toEqual({ usedPercent: 51, resetsAt: "2026-09-18T07:00:00.154Z" });
    expect(usage.scoped).toEqual([{ name: "Fable", window: { usedPercent: 8, resetsAt: "2026-09-18T07:00:00.726Z" } }]);
  });

  test("missing windows stay null instead of becoming zero usage", () => {
    const usage = parseClaudeUsage({ five_hour: { utilization: 3 } }, now);
    expect(usage.session).toEqual({ usedPercent: 3, resetsAt: null });
    expect(usage.weekly).toBeNull();
  });
});
