# AI Switch 0.10.1 — Beta

## aiswitch list shows account IDs

- `aiswitch list` now starts with an **ID** column: the first 8 characters of each account's id. Pass it to `aiswitch use` to switch to exactly that account, for example `aiswitch use 2b461471`. An email isn't always unique, since one login can sign in to several Claude organizations, each saved as its own account; the ID always is.
- Under the table, a line now shows how to switch: `aiswitch use <ID or ACCOUNT>`.
- To keep the table narrow, account lists name Claude Code **CC**: the table and the list `use` gives when a name or email matches several accounts. `--provider claude` is unchanged.

99 Mac and 14 server regression tests pass.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
