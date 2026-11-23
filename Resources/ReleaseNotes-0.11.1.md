# AI Switch 0.11.1 — Beta

## Antigravity fixes

- **Add account** and **Sign in again…** now work for Antigravity. `agy acp --login` ends on a Google page that shows an authorization code, and the sign-in window now has a field for it (paste the code or the page's address), plus a link to open the sign-in page again.
- Switching while another Antigravity account renews in the background can no longer leave `agy` signed in to the wrong account or save one account's sign-in into another's. Switching, checks, sign-in, and renewal now take turns at `agy`'s single Keychain entry.
- If the Keychain can't be read, a sign-in or renewal now stops before changing anything instead of signing `agy` out. A failed Keychain write no longer leaves later sign-ins and renewals waiting until the app restarts.
- Renewal now uses only `agy models`, which uses no model quota. The one-turn `agy -p` fallback is gone: when Google couldn't be reached, it waited a minute for a sign-in code nobody could enter and left an unusable sign-in link on the card. A failed renewal now says to check the connection or sign in again, and a renewal that comes back signed in to another account is refused.
- AI Switch now reads the account email that `agy` 1.5 saves with its sign-in, so usage checks no longer ask Google whose account it is. An expired `agy` sign-in for another email is never saved into a saved account.
- Usage shows only the limits Antigravity reports, under their own names. The `retrieveUserQuota` fallback, which showed per-model quotas as the 5-hour and weekly rings, is gone, and Claude/GPT limits no longer stand in for Gemini's when the Gemini group is missing. An account without a quota summary shows a note instead. The phone sync server does the same, and the Mac no longer sends it the account's project ID.
- AI Switch no longer relies on `Process.waitUntilExit()` to wait for a CLI to exit. It could wait forever when a command was stopped just as it exited.

110 Mac and 17 server regression tests pass, now using the sign-in format `agy` 1.5 actually writes.

Requires macOS 14 or newer and the Codex, Claude Code, and/or Antigravity CLI (`agy`) installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
