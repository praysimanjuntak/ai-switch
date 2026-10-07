# AI Switch 0.6.0 — Beta

## Switch omp too

- If omp is installed, a **Switch omp too** toggle appears next to the search field. While it's on, the account you switch to for Codex or Claude Code also becomes the one omp prefers for new omp sessions, and its row shows an **omp** tag.
- omp keeps its own sign-ins, and AI Switch never reads or copies omp's tokens. It adds one rule per provider to omp's `auth.accountPolicies` setting with `omp config set`, giving the account the highest priority. omp still falls back to its other accounts when the preferred one runs low, and a running omp session keeps its account while it's in use.
- An account has to be signed in to omp (`/login` in omp) for omp to use it; otherwise its row says **Not in omp** and omp keeps choosing its own account.
- Your own `auth.accountPolicies` rules are kept. If one of them already targets the account, AI Switch leaves omp's choice to it.
- If omp drops the preferred account (a logout or a failed refresh), AI Switch removes its rule within seconds, since omp would otherwise reject every request for that provider. Turning the toggle off removes AI Switch's rules.

## Tidier rows

- A row's right side now holds only **Switch** and its menu, centered. How fresh the usage is moved next to the account's resets: "Live", "Updated 3 min ago", "Updated 3 h ago", or "Updated 6 Oct".

73 Mac and 14 server regression tests pass, including matching accounts to omp by workspace, keeping the user's own omp rules, and removing AI Switch's rule when an account leaves omp. On a real omp install, omp's own account balancer chose the preferred account for 20 of 20 test sessions for each Codex account.

Requires macOS 14 or newer and the Codex and/or Claude Code CLI installed separately. This beta is ad-hoc signed and is not notarized by Apple. Existing CLI sessions retain their account; start a new session after switching. Intel builds are cross-compiled and still need testing on physical Intel hardware.
