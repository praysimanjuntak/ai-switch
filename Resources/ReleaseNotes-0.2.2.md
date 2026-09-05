# AI Switch 0.2.2 — Beta

A compact, native macOS workspace for switching between Codex and Claude Code accounts.

## Highlights

- Searchable account rows, provider filters, and menu-bar account switching.
- Five-hour and weekly usage meters with precise local reset times. Hover for the full date, seconds, and timezone.
- Silent background Keychain checks and in-memory reuse of one-time approvals for usage refreshes.
- Universal DMG containing Apple Silicon and Intel builds, an Applications shortcut, and installation notes.

## Install

Download `AI-Switch-0.2.2-macOS-universal-beta.dmg`, open it, drag AI Switch to Applications, eject the image, and launch the installed copy. Requires macOS 14 or newer. Install the Codex and/or Claude Code CLI separately and sign in with your own accounts. The DMG includes no saved accounts or credentials.

## Beta limitations

- **Ad-hoc signed, not notarized by Apple.** Gatekeeper may block launch. Only if you trust this build, follow [Apple's per-app approval instructions](https://support.apple.com/en-us/102445). Do not disable system-wide security protections. Managed Macs may prevent overrides.
- Account import, switching, and explicit grants can request Keychain access. Replacing an ad-hoc build can require a fresh approval.
- Existing CLI sessions can retain their previous account. Start a new session after switching.
- Provider integrations are experimental and can change.
- All 27 regression tests pass on the build Mac. The Intel executable is cross-compiled, not tested on physical Intel hardware; clean-machine and oldest-supported-macOS testing remain outstanding.

## Verify your download

Download the matching `.sha256` file into the same directory as the DMG, then run:

```sh
shasum -a 256 -c AI-Switch-0.2.2-macOS-universal-beta.dmg.sha256
```

This is an independent project, not an official OpenAI or Anthropic app.
