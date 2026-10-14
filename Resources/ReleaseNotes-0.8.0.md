# AI Switch 0.8.0 — Beta

## Install with Homebrew

- `brew install --cask praysimanjuntak/tap/ai-switch` installs this release, and `brew upgrade --cask ai-switch` updates it. Homebrew installs the same ad-hoc-signed build, so the first launch still needs **System Settings → Privacy & Security → Open Anyway**.

## Accounts as cards, usage as rings

- Accounts show as cards, three to a row, still grouped into Active and Other accounts.
- Each card shows up to three limits as rings: 5-hour, weekly, then a per-model weekly limit such as Claude's Fable bucket. The arc is what's left: green while plenty is left, yellow as it runs down, red near the end. The percentage left is written inside, the reset time underneath.
- The menu-bar panel uses the same rings.

## Usage every five minutes

- Every account is checked every five minutes again, instead of every minute. Anthropic refused Claude usage checks at the one-minute pace, which kept the usage of affected accounts hours old. Codex usage still arrives within seconds of each turn.

## Fixed: a failed renewal could leave a Claude account without its sign-in

- Claude Code moves an account's saved sign-in into the Keychain as soon as a renewal starts. When the renewal then failed, for example right after the Mac woke and before it was back online, 0.7.0 didn't move the sign-in back. The account showed "No saved Claude Code credentials were found", and removing it as suggested meant signing in again.
- AI Switch now moves the sign-in back after every renewal, whether or not it worked.
- If an account still shows that message after updating, choose **Renew sign-in** instead of removing it: Claude Code still has the sign-in, and AI Switch takes it back.

77 Mac and 14 server regression tests pass, including keeping an account's sign-in when a renewal fails.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
