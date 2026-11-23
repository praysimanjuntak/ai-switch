# AI Switch 0.11.0 — Beta

## Antigravity CLI (`agy`) support

- Add, import, and switch between **Antigravity CLI (`agy`)** accounts alongside Codex and Claude Code.
- Each Antigravity profile is stored in an owner-only (`0600`) `credentials.json` inside its profile directory. Switching swaps Antigravity's live login Keychain entry (`gemini` / `antigravity`, `go-keyring-base64:`-encoded via `/usr/bin/security`, or its fallback `~/.gemini/antigravity-cli/antigravity-oauth-token`) after preserving any token `agy` refreshed on the outgoing account.
- **Add account** and **Sign in again…** run `agy acp --login` and always snapshot and restore your prior live sign-in if cancelled, failed, or signed in to another Google account.
- Usage cards and the menu-bar panel read Antigravity's 5-hour, weekly, and shared **Claude/GPT** quota limits plus subscription tier from Cloud Code Assist (`loadCodeAssist` and `retrieveUserQuotaSummary`, falling back to `retrieveUserQuota`), and automatically renew expired access tokens via `agy models` (with a one-turn `agy -p` fallback) when `agy` is idle.
- `aiswitch` supports `--provider antigravity` (as well as `agy`) and lists Antigravity accounts as **AGY**; **Switch omp too** maps to `google-antigravity`; and the optional phone sync server + web app display live Antigravity limits.

105 Mac and 18 server regression tests pass, covering keyring encoding, Go OAuth token parsing and refresh merging, quota summary and fallback parsing, `agy` login/renewal Keychain restoration, running-process renewal guards, `aiswitch`, `omp`, and phone sync.

Requires macOS 14 or newer and the Codex, Claude Code, and/or Antigravity CLI (`agy`) installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
