# AI Switch 0.4.0 — Beta

## Accounts in rows, on a white canvas

- The window is redesigned: pure white, neutral grays, and monochrome provider marks. Color only marks status: green for active and live, amber when a limit runs low, red when it is nearly gone.
- Each account is one row with its 5-hour, weekly, and per-model (for example Fable) meters and their reset times, in columns that line up down the list, plus its plan, a **Switch** button, and how fresh its usage is ("Live" when under a minute old).
- The sidebar and summary cards are gone. A title row holds the actions, filter pills pick a provider, and the list is split into **Active** and **Other accounts**.
- The menu-bar panel and the **Add account** and **Phone** sheets follow the same style. Errors appear as a toast above the footer instead of over the toolbar.

## Live Codex usage

- Codex records its rate limits in its session log after every turn. AI Switch now reads those logs every few seconds and updates the saved account that ran the turn, with no network request; each log names the account it belongs to.
- Every account is still checked every five minutes. Anthropic rate-limits Claude's usage endpoint even at 30–60 second polling, so five minutes is the safe pace there. When Anthropic refuses a check, AI Switch now waits longer before the next one (up to an hour) and says so, instead of asking you to re-authenticate.

## Your saved sign-ins stay yours

- A CLI's live sign-in is only ever saved into the profile of the account it belongs to. Before, signing in to another account with `codex login` or Claude Code's `/login`, then refreshing, switching, or importing in AI Switch, overwrote the active account's saved sign-in.
- When a CLI is signed in to an account that isn't saved, the previously active account keeps its own sign-in and is no longer marked active, and AI Switch suggests **Import**. If that account is already saved, it becomes the active one.
- Codex accounts are told apart by the user and ChatGPT account their tokens name. Claude credentials don't say whose they are, so AI Switch uses the account Claude Code recorded for the profile, or asks Anthropic's profile endpoint, as Claude Code itself does.
- Writing a renewed sign-in back to a CLI no longer replaces a token the CLI refreshed in the meantime.
- Imported Claude accounts now show their email.

## Phone sync

- The sync server address must use https. Plain http is only accepted for a server on this Mac, since pushes carry access tokens.

62 Mac and 14 server regression tests pass, including credential ownership on refresh, switch, import, and renewal, the live Codex session feed and its account attribution, the rate-limit backoff, and https-only sync.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
