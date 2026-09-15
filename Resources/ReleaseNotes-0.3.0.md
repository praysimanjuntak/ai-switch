# AI Switch 0.3.0 — Beta

## Claude Code accounts without Keychain permission dialogs

- Saved Claude Code profiles are now owner-only `.credentials.json` files inside their profile directories, the same file Claude Code reads when `CLAUDE_CONFIG_DIR` points there. Nothing is stored in the Keychain for saved accounts.
- The live credential Claude Code uses for new sessions is read and written through `/usr/bin/security`, exactly as Claude Code does, so macOS no longer shows "AI Switch wants to use your confidential information" dialogs. **Grant access**, "Always Allow" advice, and the paused-refresh state are gone.
- Switching saves the outgoing account's current credential back into its profile first, so a token Claude Code refreshed meanwhile is kept. Refreshing the active account keeps its profile file in sync.
- An access token past its expiry is reported as needing renewal (start a Claude Code session with that account, then refresh) instead of as a rejected sign-in.
- Upgrading from 0.2.x: the active Claude account migrates itself on the first refresh. Other saved Claude accounts show **Attention** and must be removed and added again; removing them also deletes the old Keychain item.

## Account grid

- Accounts are shown as cards in a four-column grid instead of a list. Each card has both usage meters with reset times, the plan, and the switch action.
- The main window now opens at 1180×760 and has a minimum width of 1120 to keep four cards readable.
- The active account can now be removed. AI Switch forgets it and deletes its saved credentials; the CLI keeps its current sign-in until you switch or sign out there.
- Codex and Claude Code are marked with the OpenAI and Anthropic logos (bundled under `Contents/Resources/AISwitch_AISwitch.bundle`) instead of generic symbols.
- Refresh all checks every account at the same time instead of one after another, so one slow provider check no longer delays the rest.

## Usage on your phone

- New **Phone** toolbar button connects this Mac to a self-hosted sync server (`Server/`, Bun + SQLite, deploy with `Scripts/deploy-server.sh`) and shows a QR code that pairs a phone with a read-only web app.
- Claude's per-model weekly buckets (for example the Fable limit) appear as extra meters on the Mac, in the menu bar, and on the phone.
- The server reads usage straight from the providers with each account's short-lived access token, so the phone stays accurate while the Mac is off and when the accounts are used elsewhere. Refresh tokens never leave the Mac.
- The web app installs from Chrome on Android, caches the last usage for offline viewing, and keeps reset countdowns running locally.

## Sign-in cancellation

- Cancel sign-in at any time with the Cancel button, window close button, or Escape.
- Stop the login CLI and its process-group children, with a bounded fallback for processes that ignore termination.
- Prevent cancelled or late login results from adding or activating an account.
- Clean up incomplete profile directories and avoid saving ghost accounts after activation failure.
- Retry failed sign-ins directly. Long error output scrolls without hiding the controls.

39 Mac and 14 server regression tests pass, including cancellation before launch, running-process cancellation, stubborn child processes, timeouts, late completion, profile rollback, and the Claude credential exchange on switch, refresh, and import.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
