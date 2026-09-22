import { version } from "../package.json";
import type { Provider, PushedToken, ScopedUsageWindow, UsageSnapshot, UsageWindow } from "./types";

export class TokenRejectedError extends Error {
  constructor() {
    super("The provider rejected the access token. It renews the next time the Mac checks in.");
    this.name = "TokenRejectedError";
  }
}

const FETCH_TIMEOUT_MS = 10_000;
const USER_AGENT = `ai-switch-sync/${version}`;

export async function fetchUsage(
  provider: Provider,
  token: PushedToken,
  now = new Date(),
  fetchImpl: typeof fetch = fetch,
): Promise<UsageSnapshot> {
  switch (provider) {
    case "claude":
      return fetchClaudeUsage(token, now, fetchImpl);
    case "codex":
      return fetchCodexUsage(token, now, fetchImpl);
  }
}

// Claude Code reads its limits from this endpoint with its own OAuth token.
async function fetchClaudeUsage(token: PushedToken, now: Date, fetchImpl: typeof fetch): Promise<UsageSnapshot> {
  const response = await fetchImpl("https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1", {
    headers: {
      Authorization: `Bearer ${token.accessToken}`,
      "anthropic-beta": "oauth-2025-04-20",
      "User-Agent": USER_AGENT,
    },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (response.status === 401) throw new TokenRejectedError();
  if (!response.ok) throw new Error(`Claude usage request failed (HTTP ${response.status}).`);
  return parseClaudeUsage(await response.json(), now);
}

/** `five_hour`/`seven_day` are account-wide; `limits[]` carries per-model weekly buckets. */
export function parseClaudeUsage(payload: unknown, now = new Date()): UsageSnapshot {
  const root = asRecord(payload);
  const window = (raw: unknown, usedKey: string): UsageWindow | null => {
    const limit = asRecord(raw);
    const used = asNumber(limit[usedKey]);
    if (used === null) return null;
    return { usedPercent: used, resetsAt: asISODate(limit.resets_at) };
  };
  const limits = Array.isArray(root.limits) ? (root.limits as unknown[]) : [];
  const scoped = limits.flatMap((entry): ScopedUsageWindow[] => {
    const limit = asRecord(entry);
    const bucket = window(limit, "percent");
    if (limit.kind !== "weekly_scoped" || bucket === null) return [];
    const scope = asRecord(limit.scope);
    const name = asRecord(scope.model).display_name ?? asRecord(scope.surface).display_name;
    return [{ name: typeof name === "string" ? name : "Scoped", window: bucket }];
  });
  return {
    session: window(root.five_hour, "utilization"),
    weekly: window(root.seven_day, "utilization"),
    scoped,
    fetchedAt: now.toISOString(),
    note: null,
  };
}

// The same endpoint `codex app-server` uses for account/rateLimits/read.
async function fetchCodexUsage(token: PushedToken, now: Date, fetchImpl: typeof fetch): Promise<UsageSnapshot> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token.accessToken}`,
    "User-Agent": USER_AGENT,
  };
  if (token.accountId) headers["ChatGPT-Account-Id"] = token.accountId;
  const response = await fetchImpl("https://chatgpt.com/backend-api/wham/usage", {
    headers,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (response.status === 401 || response.status === 403) throw new TokenRejectedError();
  if (!response.ok) throw new Error(`Codex usage request failed (HTTP ${response.status}).`);
  return parseCodexUsage(await response.json(), now);
}

const SIX_HOURS = 6 * 60 * 60;
const SIX_DAYS = 6 * 24 * 60 * 60;

export function parseCodexUsage(payload: unknown, now = new Date()): UsageSnapshot {
  const rateLimit = asRecord(asRecord(payload).rate_limit);
  const windows: { seconds: number | null; window: UsageWindow }[] = [];
  for (const key of ["primary_window", "secondary_window"]) {
    const raw = asRecord(rateLimit[key]);
    const used = asNumber(raw.used_percent);
    if (used === null) continue;
    const resetSeconds = asNumber(raw.reset_at);
    windows.push({
      seconds: asNumber(raw.limit_window_seconds),
      window: { usedPercent: used, resetsAt: resetSeconds === null ? null : new Date(resetSeconds * 1000).toISOString() },
    });
  }
  const session = windows.filter((w) => (w.seconds ?? Infinity) <= SIX_HOURS).sort((a, b) => (a.seconds ?? 0) - (b.seconds ?? 0))[0]?.window ?? null;
  const weekly =
    windows.filter((w) => (w.seconds ?? 0) >= SIX_DAYS).sort((a, b) => (b.seconds ?? 0) - (a.seconds ?? 0))[0]?.window ??
    (windows.length === 1 && (windows[0].seconds ?? 0) > SIX_HOURS ? windows[0].window : null);
  return {
    session,
    weekly,
    fetchedAt: now.toISOString(),
    note: windows.length === 0 ? "Codex did not report a rolling limit for this account." : null,
  };
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function asNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asISODate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}
