# AI Switch 0.8.1 — Beta

## Fixed: Claude Code showed the previous account's email after a switch

- Claude Code shows the account named in its own settings file (`~/.claude.json`): the email, organization, and plan details in its welcome screen, `/status`, and `claude auth status`. It keeps that record apart from the sign-in and refetches it only about once a day. AI Switch switched only the sign-in, so Claude Code could show the new account's plan with the previous account's email and organization, for example a Team plan next to a personal account's email.
- Switching now also replaces that record with the incoming account's own, the one Claude Code saved when the account signed in. AI Switch takes the same lock Claude Code takes when it writes the file and changes nothing else in it.
- A record left naming the wrong account by an earlier version is corrected at 0.8.1's first check, a few seconds after launch. Claude Code sessions that were already running keep showing what they read when they started; start a new session.

84 Mac and 14 server regression tests pass, including switching accounts, repairing a wrong record, leaving a `/login` made in Claude Code alone, and waiting for Claude Code's lock.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
