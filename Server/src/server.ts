import { timingSafeEqual } from "node:crypto";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { fetchUsage, TokenRejectedError } from "./providers";
import { Store, type StoredAccount } from "./store";
import type { PushRequest, PushedAccount, ViewResponse, ViewedAccount } from "./types";

const LIVE_USAGE_TTL_MS = 60_000;
const MAX_PUSH_BYTES = 256 * 1024;
const PUBLIC_DIR = join(import.meta.dir, "..", "public");

export interface ServerOptions {
  pushSecret: string;
  store: Store;
  /** Public origin used in pairing links, e.g. https://aiswitch.example.com */
  publicOrigin: string;
  fetchImpl?: typeof fetch;
  now?: () => Date;
}

export function createHandler(options: ServerOptions) {
  const { pushSecret, store } = options;
  const fetchImpl = options.fetchImpl ?? fetch;
  const now = options.now ?? (() => new Date());

  return async function handle(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/healthz") return json({ ok: true });

    const devicePush = path.match(/^\/api\/devices\/([A-Za-z0-9-]{1,64})\/(accounts|viewers)$/);
    if (devicePush) {
      if (!bearerMatches(request, pushSecret)) return json({ error: "unauthorized" }, 401);
      const [, deviceId, resource] = devicePush;
      if (resource === "accounts" && request.method === "PUT") {
        const body = await readPush(request);
        if (body instanceof Response) return body;
        store.replaceAccounts(deviceId, body.pushedAt, body.accounts);
        return new Response(null, { status: 204 });
      }
      if (resource === "viewers" && request.method === "POST") {
        const token = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
        store.addViewer(deviceId, await sha256(token), now().toISOString());
        return json({ token, url: `${options.publicOrigin}/#v=${token}` }, 201);
      }
      if (resource === "viewers" && request.method === "DELETE") {
        return json({ revoked: store.revokeViewers(deviceId) });
      }
      return json({ error: "method not allowed" }, 405);
    }

    if (path === "/api/view" && request.method === "GET") {
      const token = bearer(request);
      const deviceId = token ? store.deviceForViewer(await sha256(token)) : null;
      if (!deviceId) return json({ error: "unauthorized" }, 401);
      return json(await buildView(deviceId), 200, { "Cache-Control": "no-store" });
    }

    if (request.method === "GET" || request.method === "HEAD") return serveStatic(path);
    return json({ error: "not found" }, 404);
  };

  async function buildView(deviceId: string): Promise<ViewResponse> {
    const accounts = store.accounts(deviceId);
    const current = now();
    await Promise.all(accounts.map((account) => refreshIfStale(deviceId, account, current)));
    const viewed: ViewedAccount[] = store.accounts(deviceId).map((account) => ({
      id: account.id,
      provider: account.provider,
      displayName: account.displayName,
      email: account.email,
      plan: account.plan,
      isActive: account.isActive,
      usage: account.usage,
      usageSource: account.usageSource,
      usageError: account.usageError,
      tokenExpiresAt: account.token?.expiresAt ?? null,
    }));
    return { device: { lastPushAt: store.lastPushAt(deviceId) }, accounts: viewed, generatedAt: current.toISOString() };
  }

  /** Fetches live usage when the cached copy is older than the TTL and the
   *  token is still valid. Failures keep the last usage and record the reason. */
  async function refreshIfStale(deviceId: string, account: StoredAccount, current: Date): Promise<void> {
    if (!account.token) return;
    if (account.token.expiresAt && new Date(account.token.expiresAt) <= current) {
      store.recordUsageError(deviceId, account.id, "The access token has expired. It renews the next time the Mac checks in.");
      return;
    }
    // Usage the Mac fetched moments ago is as good as our own; only re-check past the TTL.
    const fetchedAt = account.usage ? new Date(account.usage.fetchedAt).getTime() : 0;
    if (account.usage && current.getTime() - fetchedAt < LIVE_USAGE_TTL_MS) return;
    try {
      store.recordUsage(deviceId, account.id, await fetchUsage(account.provider, account.token, current, fetchImpl));
    } catch (error) {
      const message = error instanceof TokenRejectedError ? error.message : `Usage check failed: ${error instanceof Error ? error.message : String(error)}`;
      store.recordUsageError(deviceId, account.id, message);
    }
  }

  async function readPush(request: Request): Promise<PushRequest | Response> {
    const length = Number(request.headers.get("content-length") ?? "0");
    if (length > MAX_PUSH_BYTES) return json({ error: "payload too large" }, 413);
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }
    const problem = validatePush(body);
    return problem ? json({ error: problem }, 400) : (body as PushRequest);
  }
}

function validatePush(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return "body must be an object";
  const push = body as Partial<PushRequest>;
  if (typeof push.pushedAt !== "string" || Number.isNaN(Date.parse(push.pushedAt))) return "pushedAt must be an ISO date";
  if (!Array.isArray(push.accounts)) return "accounts must be an array";
  for (const account of push.accounts as Partial<PushedAccount>[]) {
    if (typeof account?.id !== "string" || account.id.length === 0) return "account id missing";
    if (account.provider !== "codex" && account.provider !== "claude") return `unknown provider for ${account.id}`;
    if (typeof account.displayName !== "string") return `displayName missing for ${account.id}`;
    if (typeof account.isActive !== "boolean") return `isActive missing for ${account.id}`;
    // Optional fields may be omitted entirely (Swift's encoder drops nil keys).
    if (account.token != null && typeof account.token.accessToken !== "string") return `token malformed for ${account.id}`;
  }
  return null;
}

function bearer(request: Request): string | null {
  const header = request.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : null;
}

function bearerMatches(request: Request, secret: string): boolean {
  const presented = bearer(request);
  if (!presented) return false;
  const a = Buffer.from(presented);
  const b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Buffer.from(digest).toString("hex");
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...headers },
  });
}

const STATIC_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

async function serveStatic(path: string): Promise<Response> {
  const relative = path === "/" ? "index.html" : path.replace(/^\/+/, "");
  if (relative.includes("..")) return json({ error: "not found" }, 404);
  const file = Bun.file(join(PUBLIC_DIR, relative));
  if (!(await file.exists())) return json({ error: "not found" }, 404);
  const type = STATIC_TYPES[relative.slice(relative.lastIndexOf("."))] ?? "application/octet-stream";
  return new Response(file, { headers: { "Content-Type": type, "Cache-Control": "no-cache" } });
}

if (import.meta.main) {
  const pushSecret = Bun.env.AISWITCH_PUSH_SECRET;
  if (!pushSecret || pushSecret.length < 16) {
    console.error("AISWITCH_PUSH_SECRET must be set (16+ characters).");
    process.exit(1);
  }
  const dataDir = Bun.env.AISWITCH_DATA_DIR ?? join(import.meta.dir, "..", "data");
  mkdirSync(dataDir, { recursive: true });
  const port = Number(Bun.env.PORT ?? 8787);
  const publicOrigin = (Bun.env.AISWITCH_PUBLIC_ORIGIN ?? `http://localhost:${port}`).replace(/\/$/, "");
  const handler = createHandler({ pushSecret, store: new Store(join(dataDir, "sync.sqlite")), publicOrigin });
  Bun.serve({ port, fetch: handler });
  console.log(`ai-switch-sync listening on :${port}, pairing links use ${publicOrigin}`);
}
