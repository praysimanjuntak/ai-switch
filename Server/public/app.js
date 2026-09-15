// Read-only viewer for AI Switch usage. The pairing token arrives in the URL
// fragment from the QR code and is kept in localStorage; the last successful
// view is cached so the page still renders offline.
(() => {
  const TOKEN_KEY = "aiswitch.viewerToken";
  const CACHE_KEY = "aiswitch.lastView";
  const REFRESH_MS = 60_000;

  const el = {
    status: document.getElementById("status"),
    refresh: document.getElementById("refresh"),
    pair: document.getElementById("pair"),
    error: document.getElementById("error"),
    accounts: document.getElementById("accounts"),
    updated: document.getElementById("updated"),
    unpair: document.getElementById("unpair"),
    card: document.getElementById("card"),
  };

  let view = null;
  let loading = false;

  function adoptTokenFromURL() {
    const match = location.hash.match(/[#&]v=([A-Za-z0-9_-]{16,})/);
    if (!match) return false;
    localStorage.setItem(TOKEN_KEY, match[1]);
    localStorage.removeItem(CACHE_KEY);
    history.replaceState(null, "", location.pathname);
    return true;
  }

  async function load() {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) {
      el.pair.classList.remove("hidden");
      el.unpair.classList.add("hidden");
      el.status.textContent = "Not paired";
      return;
    }
    el.pair.classList.add("hidden");
    el.unpair.classList.remove("hidden");
    if (loading) return;
    loading = true;
    el.refresh.classList.add("spinning");
    try {
      const response = await fetch("/api/view", { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" });
      if (response.status === 401) {
        localStorage.removeItem(TOKEN_KEY);
        showError("This phone's pairing was revoked. Scan a new QR code from AI Switch on your Mac.");
        el.pair.classList.remove("hidden");
        return;
      }
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      view = await response.json();
      localStorage.setItem(CACHE_KEY, JSON.stringify(view));
      el.error.classList.add("hidden");
    } catch (error) {
      const cached = localStorage.getItem(CACHE_KEY);
      view = cached ? JSON.parse(cached) : view;
      showError(`Could not reach the sync server (${error.message}). ${view ? "Showing the last usage this phone saw." : ""}`);
    } finally {
      loading = false;
      el.refresh.classList.remove("spinning");
      render();
    }
  }

  function showError(message) {
    el.error.textContent = message;
    el.error.classList.remove("hidden");
  }

  function render() {
    const now = new Date();
    if (!view) {
      el.status.textContent = localStorage.getItem(TOKEN_KEY) ? "No data yet" : "Not paired";
      return;
    }
    const lastPush = view.device.lastPushAt ? new Date(view.device.lastPushAt) : null;
    el.status.textContent = lastPush ? `Mac checked in ${relative(lastPush, now)}` : "Mac has not checked in yet";
    el.updated.textContent = `Updated ${relative(new Date(view.generatedAt), now)}`;

    el.accounts.replaceChildren(
      ...view.accounts.map((account) => {
        const node = el.card.content.firstElementChild.cloneNode(true);
        node.dataset.provider = account.provider;
        node.classList.toggle("active", account.isActive);
        node.querySelector(".logo").src = account.provider === "codex" ? "/openai.svg" : "/anthropic.png";
        node.querySelector(".name").textContent = account.displayName;
        node.querySelector(".subtitle").textContent = account.email || account.plan || (account.provider === "codex" ? "Codex" : "Claude Code");
        node.querySelector(".active-pill").classList.toggle("hidden", !account.isActive);
        const plan = node.querySelector(".plan");
        if (account.plan) {
          plan.textContent = account.plan.replace(/_/g, " ");
          plan.classList.remove("hidden");
        }
        const stale = Boolean(account.usageError);
        for (const meter of node.querySelectorAll(".meter")) {
          renderMeter(meter, account.usage?.[meter.dataset.window] ?? null, now, stale);
        }
        node.querySelector(".source").textContent = sourceLabel(account, now);
        const issue = node.querySelector(".issue");
        if (account.usageError) {
          issue.textContent = account.usageError;
          issue.classList.remove("hidden");
        }
        return node;
      }),
    );
  }

  function renderMeter(meter, window, now, stale) {
    const percent = meter.querySelector(".percent");
    const fill = meter.querySelector(".fill");
    const reset = meter.querySelector(".reset");
    meter.classList.toggle("stale", stale);
    if (!window) {
      percent.textContent = "—";
      fill.style.width = "0";
      reset.textContent = "Not reported";
      return;
    }
    const resetAt = window.resetsAt ? new Date(window.resetsAt) : null;
    // Once a reported reset has passed, the window is full again even if no one has re-checked.
    const resetPassed = resetAt !== null && resetAt <= now;
    const remaining = resetPassed ? 100 : Math.max(0, Math.min(100, 100 - window.usedPercent));
    percent.innerHTML = `${Math.round(remaining)}%<small>left</small>`;
    fill.style.width = `${remaining}%`;
    fill.classList.toggle("empty", remaining <= 10);
    fill.classList.toggle("low", remaining > 10 && remaining <= 30);
    reset.classList.toggle("passed", resetPassed);
    if (!resetAt) {
      reset.textContent = "Reset not reported";
    } else if (resetPassed) {
      reset.textContent = `Reset ${relative(resetAt, now)} · refresh to confirm`;
    } else {
      reset.textContent = `Resets ${clock(resetAt, now)} · in ${duration(resetAt - now)}`;
    }
  }

  function sourceLabel(account, now) {
    if (!account.usage) return "No usage yet";
    const fetched = new Date(account.usage.fetchedAt);
    const origin = account.usageSource === "live" ? "Checked" : "From Mac";
    let label = `${origin} ${relative(fetched, now)}`;
    if (account.tokenExpiresAt) {
      const expires = new Date(account.tokenExpiresAt);
      label += expires <= now ? " · token expired" : ` · token valid ${duration(expires - now)}`;
    }
    return label;
  }

  function relative(date, now) {
    const seconds = Math.round((now - date) / 1000);
    if (Math.abs(seconds) < 45) return seconds >= 0 ? "just now" : "in a moment";
    return seconds > 0 ? `${duration(seconds * 1000)} ago` : `in ${duration(-seconds * 1000)}`;
  }

  function duration(ms) {
    const minutes = Math.round(ms / 60_000);
    if (minutes < 60) return `${minutes} min`;
    const hours = Math.floor(minutes / 60);
    if (hours < 48) return `${hours} h${minutes % 60 ? ` ${minutes % 60} min` : ""}`;
    return `${Math.round(hours / 24)} d`;
  }

  function clock(date, now) {
    const sameDay = date.toDateString() === now.toDateString();
    const time = date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    return sameDay ? time : `${date.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${time}`;
  }

  el.refresh.addEventListener("click", () => load());
  el.unpair.addEventListener("click", () => {
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(CACHE_KEY);
    view = null;
    el.accounts.replaceChildren();
    el.error.classList.add("hidden");
    load();
  });
  window.addEventListener("hashchange", () => {
    if (adoptTokenFromURL()) {
      el.error.classList.add("hidden");
      load();
    }
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") load();
  });
  setInterval(() => {
    if (document.visibilityState === "visible") load();
  }, REFRESH_MS);
  setInterval(render, 30_000);

  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});

  adoptTokenFromURL();
  const cached = localStorage.getItem(CACHE_KEY);
  if (cached) {
    view = JSON.parse(cached);
    render();
  }
  load();
})();
