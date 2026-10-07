# AI Switch 0.5.1 — Beta

## No accidental resets

- Using a usage limit reset now takes two separate confirmations. "Use a reset…" asks "Use 1 of your N resets on this account?" with **Cancel** and **Continue**, then a final "This can't be undone" step with a red **Yes, reset now** button.
- The buttons swap sides between the two steps, so a second click where Continue was lands on Cancel. The final button stays disabled for 1.5 seconds after it appears, and the app checks again at the moment of the click.
- Escape cancels either step, Return accepts neither, and closing the popover abandons a confirmation in progress.

## A calmer green

- Bars with plenty left use a softer sage green that sits more quietly on the white window.
- Active and Live labels use a deeper muted green, which is also easier to read as small text.

67 Mac and 14 server regression tests pass, including one that a reset can't be spent without both confirmations or within moments of the second.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
