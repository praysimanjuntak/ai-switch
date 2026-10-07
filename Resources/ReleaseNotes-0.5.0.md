# AI Switch 0.5.0 — Beta

## Usage limit resets

- Codex accounts now show how many usage limit resets they have, right under the account. Codex grants these resets to restore an account's limits early, and some of them expire.
- Click the pill to see the available resets, soonest to expire first, and use one. AI Switch asks again before spending it, then reports Codex's answer: reset, nothing to reset, none left, or already used.
- Resets are spent through the Codex app-server's `account/rateLimitResetCredit/consume`, the same call Codex's own reset makes, on the account's own sign-in. Usage is read again right after, so the meters and the count update at once.
- Claude Code's limit resets are an Anthropic experiment that runs inside Claude Code, so Claude accounts show none.

## Usage as long bars

- Each limit (5-hour, weekly, and per-model weekly such as Fable) is now its own line in the account's row, with a bar that stretches with the window, what is left, and when it resets.
- Bars are green while half or more is left, yellow from 20%, and red below that.
- The menu-bar panel stacks the same limits at full width.

## Claude in its own color

- Claude Code accounts show the Anthropic mark in its orange, the same rgb(215, 119, 87) Claude Code uses for its brand.

66 Mac and 14 server regression tests pass, including reading reset credits, spending one through the app-server, handing a token renewed during the reset back to the CLI, and keeping the reset count when live Codex usage arrives.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
