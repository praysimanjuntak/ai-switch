# AI Switch 0.7.0 — Beta

## Claude sign-ins renew themselves

- A Claude sign-in expires about eight hours after Claude Code last used it. Instead of showing **Needs attention** until you press **Renew sign-in**, AI Switch now renews an expired sign-in on its own, the same way the button does: one tool-less Claude Code message on that account, then a fresh usage check.
- If the renewal fails, or Claude still reports the sign-in as expired, the row says **Unable to renew sign-in** with the reason. AI Switch then waits an hour before trying again, so a broken sign-in doesn't spend quota every minute. **Renew sign-in** still tries right away.
- While Claude Code is running, its active account is left for Claude Code to renew when it's next used, because two renewals of one sign-in at the same moment can sign Claude Code out.
- Each renewal spends one small message of that account's quota. Codex renews its own sign-ins during usage checks, so nothing changes there.

## Usage every minute

- Every account's usage is now checked every minute instead of every five. Codex usage still also arrives within seconds of each turn.
- Anthropic rate-limits Claude's usage endpoint and has been reported to refuse fast polling for hours. When it refuses a check, AI Switch backs off for that account (15 minutes, doubling up to an hour) and the row says so.

76 Mac and 14 server regression tests pass, including renewing an expired sign-in on its own, reporting and pausing after a failed renewal, and leaving the active account alone while Claude Code runs.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
