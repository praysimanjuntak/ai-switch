/** Contract shared with the Mac app (RemoteSync.swift) and the PWA (public/app.js). */

export type Provider = "codex" | "claude";

export interface UsageWindow {
  usedPercent: number;
  resetsAt: string | null; // ISO 8601
}

export interface UsageSnapshot {
  session: UsageWindow | null;
  weekly: UsageWindow | null;
  fetchedAt: string; // ISO 8601
  note: string | null;
}

/** Access token only. Refresh tokens never leave the Mac. */
export interface PushedToken {
  accessToken: string;
  accountId: string | null; // Codex: ChatGPT-Account-Id header
  expiresAt: string | null; // ISO 8601; null when unknown
}

export interface PushedAccount {
  id: string;
  provider: Provider;
  displayName: string;
  email: string | null;
  plan: string | null;
  isActive: boolean;
  token: PushedToken | null;
  usage: UsageSnapshot | null;
}

export interface PushRequest {
  pushedAt: string;
  accounts: PushedAccount[];
}

export type UsageSource = "live" | "mac";

export interface ViewedAccount {
  id: string;
  provider: Provider;
  displayName: string;
  email: string | null;
  plan: string | null;
  isActive: boolean;
  usage: UsageSnapshot | null;
  usageSource: UsageSource | null;
  usageError: string | null;
  tokenExpiresAt: string | null;
}

export interface ViewResponse {
  device: { lastPushAt: string | null };
  accounts: ViewedAccount[];
  generatedAt: string;
}
