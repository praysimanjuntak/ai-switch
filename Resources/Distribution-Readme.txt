AI SWITCH — EARLY BETA

A compact account switcher for Codex and Claude Code.

REQUIREMENTS

macOS 14 Sonoma or newer, on Apple Silicon or Intel.
Install the Codex and/or Claude Code CLI separately. They are not bundled.
Swift and Xcode are not needed to run this app.
Sign in with your own accounts; this disk image contains no saved accounts.

INSTALL

1. Drag AI Switch.app onto the Applications shortcut.
2. Eject this disk image.
3. Open AI Switch from Applications, not from inside the disk image.
4. Import an existing CLI account, or choose Add account to sign in.

IMPORTANT: THIS BETA IS NOT NOTARIZED

This beta uses an ad-hoc signature, not an Apple Developer ID certificate.
macOS Gatekeeper may block a downloaded copy or show a security warning.
Only test a build you obtained directly from someone you trust. Do not disable
Gatekeeper or other system-wide security protections to install it. If you need
a normal, verified installation experience, request a signed, notarized build.

ACCOUNTS AND CREDENTIALS

Saved Claude Code profiles are owner-only .credentials.json files inside the
app's profile folders; nothing is stored in the Keychain for them. The live
credential Claude Code uses is read and written with the system "security"
tool, exactly as Claude Code does, so no Keychain permission dialogs appear.
If macOS ever does show a Keychain dialog, enter your password only into
macOS's own dialog, never send it to anyone.

Accounts saved by AI Switch 0.2.x lived in the Keychain. The active Claude
account migrates on its first refresh; other saved Claude accounts show
Attention and must be removed and added again.

Codex credentials are stored locally in restricted-access profile files. When
activating a Codex account, AI Switch sets cli_auth_credentials_store to file
in your Codex configuration and backs up existing configuration/credentials.

Switches apply to new CLI sessions; existing sessions can keep their old login.
Usage integrations depend on provider CLI/API behavior and can change. This is
an independent app, not an official OpenAI or Anthropic product.

Your profiles and credential backups live in:
  ~/Library/Application Support/AI Switch/

Do not share that folder or your CLI auth files.
Share only the DMG and, optionally, its matching SHA-256 checksum file.

TESTING STATUS

The beta includes Apple Silicon and Intel executables. The app's regression
tests run on the build Mac. Cross-compilation is not the same as testing on a
physical Intel Mac or every supported macOS version; treat this as a test build.
