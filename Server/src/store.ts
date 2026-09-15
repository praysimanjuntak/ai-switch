import { Database } from "bun:sqlite";
import type { PushedAccount, PushedToken, Provider, UsageSnapshot, UsageSource } from "./types";

export interface StoredAccount {
  id: string;
  provider: Provider;
  displayName: string;
  email: string | null;
  plan: string | null;
  isActive: boolean;
  token: PushedToken | null;
  usage: UsageSnapshot | null;
  usageSource: UsageSource | null;
  usageError: string | null;
}

interface AccountRow {
  id: string;
  provider: Provider;
  display_name: string;
  email: string | null;
  plan: string | null;
  is_active: number;
  access_token: string | null;
  account_id: string | null;
  token_expires_at: string | null;
  usage_json: string | null;
  usage_source: UsageSource | null;
  usage_error: string | null;
}

export class Store {
  private readonly db: Database;

  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        last_push_at TEXT
      );
      CREATE TABLE IF NOT EXISTS accounts (
        device_id TEXT NOT NULL,
        id TEXT NOT NULL,
        provider TEXT NOT NULL,
        display_name TEXT NOT NULL,
        email TEXT,
        plan TEXT,
        is_active INTEGER NOT NULL,
        access_token TEXT,
        account_id TEXT,
        token_expires_at TEXT,
        usage_json TEXT,
        usage_source TEXT,
        usage_error TEXT,
        PRIMARY KEY (device_id, id)
      );
      CREATE TABLE IF NOT EXISTS viewers (
        token_hash TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
    `);
  }

  /** Replaces the device's account list with what the Mac just pushed. Usage the
   *  server fetched itself is kept when the Mac's copy is older. */
  replaceAccounts(deviceId: string, pushedAt: string, accounts: PushedAccount[]): void {
    const existing = new Map(this.accounts(deviceId).map((account) => [account.id, account]));
    const upsert = this.db.prepare(`
      INSERT OR REPLACE INTO accounts
        (device_id, id, provider, display_name, email, plan, is_active, access_token, account_id, token_expires_at, usage_json, usage_source, usage_error)
      VALUES ($device, $id, $provider, $name, $email, $plan, $active, $token, $accountId, $expires, $usage, $source, $error)
    `);
    this.db.transaction(() => {
      this.db.prepare("INSERT OR REPLACE INTO devices (id, last_push_at) VALUES (?, ?)").run(deviceId, pushedAt);
      this.db.prepare("DELETE FROM accounts WHERE device_id = ?").run(deviceId);
      for (const account of accounts) {
        const previous = existing.get(account.id);
        const pushedUsage = account.usage ?? null;
        const keepLive =
          previous?.usageSource === "live" &&
          previous.usage !== null &&
          (pushedUsage === null || previous.usage.fetchedAt > pushedUsage.fetchedAt);
        const usage = keepLive ? previous!.usage : pushedUsage;
        upsert.run({
          $device: deviceId,
          $id: account.id,
          $provider: account.provider,
          $name: account.displayName,
          $email: account.email ?? null,
          $plan: account.plan ?? null,
          $active: account.isActive ? 1 : 0,
          $token: account.token?.accessToken ?? null,
          $accountId: account.token?.accountId ?? null,
          $expires: account.token?.expiresAt ?? null,
          $usage: usage ? JSON.stringify(usage) : null,
          $source: usage ? (keepLive ? "live" : "mac") : null,
          $error: keepLive ? previous!.usageError : null,
        });
      }
    })();
  }

  lastPushAt(deviceId: string): string | null {
    const row = this.db.prepare("SELECT last_push_at FROM devices WHERE id = ?").get(deviceId) as { last_push_at: string | null } | null;
    return row?.last_push_at ?? null;
  }

  accounts(deviceId: string): StoredAccount[] {
    const rows = this.db.prepare("SELECT * FROM accounts WHERE device_id = ? ORDER BY is_active DESC, provider, display_name").all(deviceId) as AccountRow[];
    return rows.map((row) => ({
      id: row.id,
      provider: row.provider,
      displayName: row.display_name,
      email: row.email,
      plan: row.plan,
      isActive: row.is_active === 1,
      token: row.access_token ? { accessToken: row.access_token, accountId: row.account_id, expiresAt: row.token_expires_at } : null,
      usage: row.usage_json ? (JSON.parse(row.usage_json) as UsageSnapshot) : null,
      usageSource: row.usage_source,
      usageError: row.usage_error,
    }));
  }

  recordUsage(deviceId: string, accountId: string, usage: UsageSnapshot): void {
    this.db
      .prepare("UPDATE accounts SET usage_json = ?, usage_source = 'live', usage_error = NULL WHERE device_id = ? AND id = ?")
      .run(JSON.stringify(usage), deviceId, accountId);
  }

  recordUsageError(deviceId: string, accountId: string, message: string): void {
    this.db.prepare("UPDATE accounts SET usage_error = ? WHERE device_id = ? AND id = ?").run(message, deviceId, accountId);
  }

  addViewer(deviceId: string, tokenHash: string, createdAt: string): void {
    this.db.prepare("INSERT INTO viewers (token_hash, device_id, created_at) VALUES (?, ?, ?)").run(tokenHash, deviceId, createdAt);
  }

  deviceForViewer(tokenHash: string): string | null {
    const row = this.db.prepare("SELECT device_id FROM viewers WHERE token_hash = ?").get(tokenHash) as { device_id: string } | null;
    return row?.device_id ?? null;
  }

  revokeViewers(deviceId: string): number {
    return this.db.prepare("DELETE FROM viewers WHERE device_id = ?").run(deviceId).changes;
  }

  close(): void {
    this.db.close();
  }
}
