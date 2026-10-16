# AI Switch 0.10.0 — Beta

## aiswitch: your accounts from a terminal or an agent

- AI Switch now comes with a command, `aiswitch`, so scripts and coding agents can see your accounts and switch between them without the window:
  - `aiswitch list` shows each account, which ones new sessions use, what needs attention, and what's left of each limit.
  - `aiswitch list --json` gives the same as JSON, for agents.
  - `aiswitch use <account>` switches the account new Claude Code or Codex sessions sign in with, like **Switch** in the app. Sessions already running keep their account.
- An account is named by its name, email, or id; the start of the id is enough. When a name or email matches more than one account, nothing switches and the answer lists them with their ids. Add `--provider claude` or `--provider codex` to choose between providers. Sign-ins are never printed.
- It installs itself. Homebrew links `aiswitch` into its `bin` folder. A copy installed from the DMG links it into `~/.local/bin`, the folder Claude Code's own installer uses, when the app starts, unless another program already uses that name.
- The running app does the switching, so the window and the command never change accounts at the same time. If AI Switch isn't running, `list` reads the saved account list and `use` starts the app in the background.

99 Mac and 14 server regression tests pass, including choosing accounts by name, email, or id, refusing unclear names, listing limits without sign-ins, and installing the command without replacing another program's.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
