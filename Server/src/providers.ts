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
const ANTIGRAVITY_ENDPOINT = "https://daily-cloudcode-pa.googleapis.com";
const ANTIGRAVITY_USER_AGENT = "antigravity/hub/2.24.0";

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
    case "antigravity":
      return fetchAntigravityUsage(token, now, fetchImpl);
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

// Antigravity CLI (`agy`) reads its grouped 5h/weekly quotas from Cloud Code Assist
// using its Google OAuth access token.
async function fetchAntigravityUsage(token: PushedToken, now: Date, fetchImpl: typeof fetch): Promise<UsageSnapshot> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token.accessToken}`,
    "Content-Type": "application/json",
    "User-Agent": ANTIGRAVITY_USER_AGENT,
  };
  const summaryResponse = await fetchImpl(`${ANTIGRAVITY_ENDPOINT}/v1internal:retrieveUserQuotaSummary`, {
    method: "POST",
    headers,
    body: "{}",
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (summaryResponse.status === 401) throw new TokenRejectedError();
  if (summaryResponse.ok) {
    const parsed = parseAntigravityQuotaSummary(await summaryResponse.json(), now);
    if (parsed.session !== null || parsed.weekly !== null || (parsed.scoped?.length ?? 0) > 0) {
      return parsed;
    }
  } else if (summaryResponse.status !== 404) {
    throw new Error(`Antigravity usage request failed (HTTP ${summaryResponse.status}).`);
  }

  let projectId = token.accountId;
  if (!projectId) {
    try {
      const init = await fetchImpl(`${ANTIGRAVITY_ENDPOINT}/v1internal:loadCodeAssist`, {
        method: "POST",
        headers,
        body: JSON.stringify({ metadata: { ideType: "ANTIGRAVITY" } }),
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      });
      if (init.status === 401) throw new TokenRejectedError();
      if (init.ok) {
        const body = asRecord(await init.json());
        const rawProject = body.cloudaicompanionProject;
        if (typeof rawProject === "string" && rawProject.length > 0) {
          projectId = rawProject;
        } else if (typeof asRecord(rawProject).id === "string" && (asRecord(rawProject).id as string).length > 0) {
          projectId = asRecord(rawProject).id as string;
        }
      }
    } catch (error) {
      if (error instanceof TokenRejectedError) throw error;
    }
  }
  const fallbackResponse = await fetchImpl(`${ANTIGRAVITY_ENDPOINT}/v1internal:retrieveUserQuota`, {
    method: "POST",
    headers,
    body: JSON.stringify(projectId ? { project: projectId } : {}),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (fallbackResponse.status === 401) throw new TokenRejectedError();
  if (!fallbackResponse.ok) throw new Error(`Antigravity usage request failed (HTTP ${fallbackResponse.status}).`);
  return parseAntigravityModelBuckets(await fallbackResponse.json(), now);
}

/** Parses Antigravity's `v1internal:retrieveUserQuotaSummary` response:
 *  Gemini 5h/weekly map to `session`/`weekly`, and third-party shared buckets
 *  (`3p-weekly` / `3p-5h`, Claude & GPT) map to `scoped` ("Claude/GPT"). */
export function parseAntigravityQuotaSummary(payload: unknown, now = new Date()): UsageSnapshot {
  const root = asRecord(payload);
  const groups = Array.isArray(root.groups) ? (root.groups as unknown[]).map(asRecord) : [];

  const tighter = (current: UsageWindow | null, candidate: UsageWindow): UsageWindow => {
    if (!current) return candidate;
    if (candidate.usedPercent > current.usedPercent) return candidate;
    if (
      candidate.usedPercent === current.usedPercent &&
      candidate.resetsAt !== null &&
      (current.resetsAt === null || candidate.resetsAt < current.resetsAt)
    ) {
      return candidate;
    }
    return current;
  };

  const bucketWindow = (bucket: Record<string, unknown>): UsageWindow | null => {
    const rawFraction = asNumber(bucket.remainingFraction);
    let remaining: number;
    if (rawFraction !== null) {
      remaining = Math.max(0, Math.min(1, rawFraction));
    } else if (bucket.remainingAmount === "0" || bucket.remainingAmount === 0) {
      remaining = 0;
    } else {
      return null;
    }
    const usedPercent = Math.round((1 - remaining) * 10_000) / 100;
    return { usedPercent, resetsAt: asISODate(bucket.resetTime) };
  };

  let gemini5h: UsageWindow | null = null;
  let geminiWeekly: UsageWindow | null = null;
  let thirdPartyWeekly: UsageWindow | null = null;
  let thirdParty5h: UsageWindow | null = null;

  for (const group of groups) {
    const groupId = typeof group.id === "string" ? group.id.toLowerCase() : "";
    const groupName =
      typeof group.displayName === "string"
        ? group.displayName.toLowerCase()
        : typeof group.label === "string"
          ? group.label.toLowerCase()
          : "";
    const groupIs3P = groupId.includes("3p") || groupName.includes("claude") || groupName.includes("gpt");
    const buckets = Array.isArray(group.buckets) ? (group.buckets as unknown[]).map(asRecord) : [];
    for (const bucket of buckets) {
      const window = bucketWindow(bucket);
      if (!window) continue;
      const bucketId =
        typeof bucket.bucketId === "string"
          ? bucket.bucketId.toLowerCase()
          : typeof bucket.id === "string"
            ? bucket.id.toLowerCase()
            : "";
      const windowKind = typeof bucket.window === "string" ? bucket.window.toLowerCase() : "";
      const displayName = typeof bucket.displayName === "string" ? bucket.displayName.toLowerCase() : "";
      const is3P = bucketId.startsWith("3p-") || groupIs3P;
      const isWeekly = windowKind.includes("week") || bucketId.includes("weekly") || displayName.includes("weekly");
      const is5h =
        windowKind.includes("5h") ||
        bucketId.includes("5h") ||
        displayName.includes("five hour") ||
        displayName.includes("5-hour") ||
        displayName.includes("5 hour");

      if (is3P) {
        if (isWeekly) {
          thirdPartyWeekly = tighter(thirdPartyWeekly, window);
        } else if (is5h) {
          thirdParty5h = tighter(thirdParty5h, window);
        } else {
          thirdPartyWeekly = tighter(thirdPartyWeekly, window);
        }
      } else {
        if (is5h) {
          gemini5h = tighter(gemini5h, window);
        } else if (isWeekly) {
          geminiWeekly = tighter(geminiWeekly, window);
        } else if (gemini5h === null) {
          gemini5h = window;
        } else {
          geminiWeekly = tighter(geminiWeekly, window);
        }
      }
    }
  }

  let scoped: ScopedUsageWindow[] = [];
  const thirdParty = thirdPartyWeekly ?? thirdParty5h;
  if (thirdParty) scoped.push({ name: "Claude/GPT", window: thirdParty });
  const session = gemini5h ?? (geminiWeekly === null ? thirdParty5h : null);
  const weekly = geminiWeekly ?? (gemini5h === null ? thirdPartyWeekly : null);
  if (gemini5h === null && geminiWeekly === null) scoped = [];
  return {
    session,
    weekly,
    scoped,
    fetchedAt: now.toISOString(),
    note: session === null && weekly === null && scoped.length === 0 ? "Antigravity did not report quota limits for this account." : null,
  };
}

/** Fallback parser for `v1internal:retrieveUserQuota` per-model buckets. */
export function parseAntigravityModelBuckets(payload: unknown, now = new Date()): UsageSnapshot {
  const root = asRecord(payload);
  const allBuckets = Array.isArray(root.buckets) ? (root.buckets as unknown[]).map(asRecord) : [];
  const nonVertex = allBuckets.filter((bucket) => !(typeof bucket.modelId === "string" && bucket.modelId.toLowerCase().endsWith("_vertex")));
  const buckets = nonVertex.length > 0 ? nonVertex : allBuckets;

  const tighter = (current: UsageWindow | null, candidate: UsageWindow): UsageWindow =>
    !current || candidate.usedPercent > current.usedPercent ? candidate : current;

  let pro: UsageWindow | null = null;
  let flash: UsageWindow | null = null;
  for (const bucket of buckets) {
    if (typeof bucket.modelId !== "string" || bucket.modelId.length === 0) continue;
    const rawFraction = asNumber(bucket.remainingFraction);
    let remaining: number;
    if (rawFraction !== null) {
      remaining = Math.max(0, Math.min(1, rawFraction));
    } else if (bucket.remainingAmount === "0" || bucket.remainingAmount === 0) {
      remaining = 0;
    } else {
      continue;
    }
    const window: UsageWindow = { usedPercent: Math.round((1 - remaining) * 10_000) / 100, resetsAt: asISODate(bucket.resetTime) };
    if (bucket.modelId.toLowerCase().includes("flash")) {
      flash = tighter(flash, window);
    } else {
      pro = tighter(pro, window);
    }
  }
  return {
    session: pro,
    weekly: flash,
    scoped: [],
    fetchedAt: now.toISOString(),
    note: pro === null && flash === null ? "Antigravity did not report quota limits for this account." : null,
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
