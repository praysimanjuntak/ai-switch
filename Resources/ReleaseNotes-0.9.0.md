# AI Switch 0.9.0 — Beta

## Sign an account in again without removing it

- When an account's sign-in can't be renewed any more, for example a Claude sign-in past its roughly 30 days or a Codex sign-in that was revoked, choose **Sign in again…** in the card's actions menu or its **Needs attention** popover. It runs the same browser sign-in as **Add account** and replaces only that account's saved sign-in. The account keeps its name, settings, and usage history, and you no longer have to remove it and add it again.
- The new sign-in is used only if it's the same account. Signing in as a different account, or in another organization or workspace of the same login, changes nothing, and the sheet says which account you signed in as. For a Claude account in an organization, the sheet names the organization to choose.
- When the account is active, Claude Code or Codex gets the new sign-in too, unless it has signed in to another account meanwhile.
- Closing the sheet before the browser sign-in finishes changes nothing, even if the sign-in completes afterwards.
- Messages that told you to remove and re-add an account now point to **Sign in again…**.

92 Mac and 14 server regression tests pass, including signing in again as the same account, refusing another account or organization, updating the CLI for the active account, cancelling, and pausing usage checks while the sign-in runs.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
