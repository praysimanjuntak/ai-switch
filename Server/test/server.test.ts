import { beforeEach, describe, expect, test } from "bun:test";
import { createHandler } from "../src/server";
import { Store } from "../src/store";
import type { PushRequest, ViewResponse } from "../src/types";

const SECRET = "test-push-secret-0123456789";
const DEVICE = "6F0F1A2B-3C4D-5E6F-7A8B-9C0D1E2F3A4B";

interface Harness {
  handle: (request: Request) => Promise<Response>;
  clock: { now: Date };
  calls: string[];
  responses: Record<string, () => Response>;
}

function harness(): Harness {
  const clock = { now: new Date("2026-09-15T16:00:00Z") };
  const calls: string[] = [];
  const responses: Record<string, () => Response> = {
    "https://chatgpt.com/backend-api/wham/usage": () =>
      Response.json({ rate_limit: { primary_window: { used_percent: 40, limit_window_seconds: 18000, reset_at: 1789498080 } } }),
    "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1": () =>
      Response.json({ five_hour: { utilization: 20, resets_at: "2026-09-15T20:00:00Z" }, seven_day: { utilization: 60, resets_at: "2026-09-18T00:00:00Z" } }),
  };
  const fetchImpl = (async (input: string | URL | Request) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    calls.push(url);
    return responses[url]?.() ?? new Response("nope", { status: 500 });
  }) as typeof fetch;
  const handle = createHandler({ pushSecret: SECRET, store: new Store(":memory:"), publicOrigin: "https://sync.example", fetchImpl, now: () => clock.now });
  return { handle, clock, calls, responses };
}

function push(accounts: PushRequest["accounts"], pushedAt = "2026-09-15T15:59:00Z"): Request {
  return new Request(`http://x/api/devices/${DEVICE}/accounts`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${SECRET}`, "Content-Type": "application/json" },
    body: JSON.stringify({ pushedAt, accounts } satisfies PushRequest),
  });
}

const codex = {
  id: "codex-1",
  provider: "codex" as const,
  displayName: "pray",
  email: "pray@example.com",
  plan: "plus",
  isActive: true,
  token: { accessToken: "codex-access", accountId: "acct-1", expiresAt: "2026-09-22T06:34:03Z" },
  usage: { session: { usedPercent: 10, resetsAt: null }, weekly: null, fetchedAt: "2026-09-15T15:58:00Z", note: null },
};
const claude = {
  id: "claude-1",
  provider: "claude" as const,
  displayName: "claude-main",
  email: null,
  plan: "pro",
  isActive: true,
  token: { accessToken: "claude-access", accountId: null, expiresAt: "2026-09-16T00:15:01Z" },
  usage: null,
};

async function pair(h: Harness): Promise<string> {
  const response = await h.handle(new Request(`http://x/api/devices/${DEVICE}/viewers`, { method: "POST", headers: { Authorization: `Bearer ${SECRET}` } }));
  expect(response.status).toBe(201);
  const body = (await response.json()) as { token: string; url: string };
  expect(body.url).toBe(`https://sync.example/#v=${body.token}`);
  return body.token;
}

async function view(h: Harness, token: string): Promise<ViewResponse> {
  const response = await h.handle(new Request("http://x/api/view", { headers: { Authorization: `Bearer ${token}` } }));
  expect(response.status).toBe(200);
  return (await response.json()) as ViewResponse;
}

describe("sync server", () => {
  let h: Harness;
  beforeEach(() => {
    h = harness();
  });

  test("rejects pushes and pairing without the push secret, and views without a viewer token", async () => {
    const noAuth = await h.handle(new Request(`http://x/api/devices/${DEVICE}/accounts`, { method: "PUT", body: "{}" }));
    expect(noAuth.status).toBe(401);
    const wrong = await h.handle(new Request(`http://x/api/devices/${DEVICE}/viewers`, { method: "POST", headers: { Authorization: "Bearer nope" } }));
    expect(wrong.status).toBe(401);
    const anonymous = await h.handle(new Request("http://x/api/view", { headers: { Authorization: "Bearer made-up" } }));
    expect(anonymous.status).toBe(401);
  });

  test("a viewer sees live usage fetched with the pushed access tokens", async () => {
    expect((await h.handle(push([codex, claude]))).status).toBe(204);
    const token = await pair(h);
    const result = await view(h, token);
    expect(result.device.lastPushAt).toBe("2026-09-15T15:59:00Z");
    expect(result.accounts.map((a) => a.id)).toEqual(["claude-1", "codex-1"]);
    const seen = Object.fromEntries(result.accounts.map((a) => [a.id, a]));
    expect(seen["codex-1"].usage?.session?.usedPercent).toBe(40);
    expect(seen["codex-1"].usageSource).toBe("live");
    expect(seen["claude-1"].usage?.weekly?.usedPercent).toBe(60);
    expect(seen["claude-1"].tokenExpiresAt).toBe("2026-09-16T00:15:01Z");
    expect(JSON.stringify(result)).not.toContain("codex-access");
    expect(h.calls).toHaveLength(2);
  });

  test("live usage is cached for a minute across views", async () => {
    await h.handle(push([codex]));
    const token = await pair(h);
    await view(h, token);
    await view(h, token);
    expect(h.calls).toHaveLength(1);
    h.clock.now = new Date(h.clock.now.getTime() + 61_000);
    await view(h, token);
    expect(h.calls).toHaveLength(2);
  });

  test("an expired token keeps the last usage and explains that the Mac must check in", async () => {
    await h.handle(push([codex]));
    const token = await pair(h);
    await view(h, token);
    h.clock.now = new Date("2026-09-23T00:00:00Z");
    const result = await view(h, token);
    expect(result.accounts[0].usage?.session?.usedPercent).toBe(40);
    expect(result.accounts[0].usageError).toContain("expired");
    expect(h.calls).toHaveLength(1);
  });

  test("a rejected token is reported without discarding the last usage", async () => {
    await h.handle(push([claude]));
    const token = await pair(h);
    await view(h, token);
    h.responses["https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1"] = () => new Response("", { status: 401 });
    h.clock.now = new Date(h.clock.now.getTime() + 61_000);
    const result = await view(h, token);
    expect(result.accounts[0].usage?.session?.usedPercent).toBe(20);
    expect(result.accounts[0].usageError).toContain("rejected");
  });

  test("a later push keeps newer live usage but adopts the Mac's copy when it is fresher", async () => {
    await h.handle(push([codex]));
    const token = await pair(h);
    await view(h, token); // live at 16:00
    await h.handle(push([{ ...codex, usage: { ...codex.usage, fetchedAt: "2026-09-15T15:30:00Z" } }], "2026-09-15T16:00:30Z"));
    let result = await view(h, token);
    expect(result.accounts[0].usage?.session?.usedPercent).toBe(40);
    expect(result.accounts[0].usageSource).toBe("live");
    await h.handle(push([{ ...codex, usage: { ...codex.usage, session: { usedPercent: 55, resetsAt: null }, fetchedAt: "2026-09-15T16:00:45Z" } }], "2026-09-15T16:00:50Z"));
    result = await view(h, token);
    expect(result.accounts[0].usage?.session?.usedPercent).toBe(55);
    expect(result.accounts[0].usageSource).toBe("mac");
  });

  test("revoking viewers invalidates pairing links", async () => {
    await h.handle(push([codex]));
    const token = await pair(h);
    const revoke = await h.handle(new Request(`http://x/api/devices/${DEVICE}/viewers`, { method: "DELETE", headers: { Authorization: `Bearer ${SECRET}` } }));
    expect(await revoke.json()).toEqual({ revoked: 1 });
    const after = await h.handle(new Request("http://x/api/view", { headers: { Authorization: `Bearer ${token}` } }));
    expect(after.status).toBe(401);
  });

  test("malformed pushes are rejected before touching stored accounts", async () => {
    await h.handle(push([codex]));
    const bad = await h.handle(push([{ ...codex, provider: "gemini" as never }]));
    expect(bad.status).toBe(400);
    const token = await pair(h);
    expect((await view(h, token)).accounts).toHaveLength(1);
  });

  test("accepts a push whose optional fields are omitted, as the Mac encoder does", async () => {
    const minimal = { id: "claude-2", provider: "claude", displayName: "Claude Code account", isActive: false };
    const response = await h.handle(
      new Request(`http://x/api/devices/${DEVICE}/accounts`, {
        method: "PUT",
        headers: { Authorization: `Bearer ${SECRET}`, "Content-Type": "application/json" },
        body: JSON.stringify({ pushedAt: "2026-09-15T15:59:00Z", accounts: [minimal] }),
      }),
    );
    expect(response.status).toBe(204);
    const result = await view(h, await pair(h));
    expect(result.accounts[0]).toMatchObject({ id: "claude-2", email: null, plan: null, usage: null, usageError: null, tokenExpiresAt: null });
    expect(h.calls).toHaveLength(0);
  });

  test("serves the PWA shell", async () => {
    const index = await h.handle(new Request("http://x/"));
    expect(index.status).toBe(200);
    expect(index.headers.get("content-type")).toContain("text/html");
    const escape = await h.handle(new Request("http://x/../src/server.ts"));
    expect(escape.status).toBe(404);
  });
});
