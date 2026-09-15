# Changelog

## Unreleased

### Portability: made it work on any supported Mac, not only the author's

A pre-release audit found the project had no hardcoded paths or usernames, but
had absorbed its author's machine in subtler ways.

- **The tracked-source hard stop failed open without Xcode.** `/usr/bin/git` is
  a Command Line Tools stub; when it cannot run, `git ls-files` exits non-zero
  and that was read as "not tracked", so a committed `vendor/` or `dist/` became
  deletable as build output. It now fails closed, and `preflight`/`doctor`
  report whether git is usable.
- **The guard was more permissive on Intel.** `ALLOW /usr/local` meant the whole
  live Homebrew install was `ALLOW` on Intel while the same install was denied
  on Apple Silicon. All three package-manager prefixes (`/usr/local`,
  `/opt/homebrew`, `/opt/local`) are now denied by name, so default-deny no
  longer depends on the chip, and name rules can no longer tunnel into them.
- **Sizes were locale-dependent.** `awk printf` honours `LC_NUMERIC`, so on a
  comma-decimal Mac every size read "1,0 KB" and `--min 1.5G` silently scanned
  at 1.0 GiB. The suite now runs under `de_DE.UTF-8` in CI.
- **`cmai_denest` double-counted.** It assumed a byte sort puts a parent
  adjacent to its descendants; `-` sorts before `/`, so `my-app.old` next to
  `my-app` broke it. Rewritten to test each path against its own ancestors.
- **A catalog row the guard could never permit.** `ASK ~/Library/Containers`
  shared the `DENY`'s pattern string, and a permissive rule must be strictly
  longer, so Mail attachments were offered by the scan and always refused.
- **`doctor` reported all-green on a dead safety kernel.** Its self-test only
  asserted refusals, which a broken guard satisfies trivially. It now checks
  `$REALPATH` and `$GIT`, and asserts one path it must *permit*.
- **Tests that only passed here.** `cases-guard.tsv` asserted on `/usr/local/bin`
  (created by macFUSE on the author's machine) and on iCloud's directory;
  `mkfixture.sh` called `/usr/bin/mkfile`, which is at `/usr/sbin`, so the
  sparse-file assertion had never run.
- **CI now tests the claim.** `macos-latest` had become the author's exact OS and
  architecture. The matrix is `macos-15`, `macos-15-intel`, `macos-26`,
  `macos-26-intel`, the OS gate is no longer skipped, a `macos-14` job asserts
  the floor refuses, and the suite runs under a comma-decimal locale.
- Coverage for other people's software: risky rules for Dropbox, Google Drive,
  Parallels, UTM, VMware, Creative Cloud and Backblaze; dev caches for Cursor,
  Zed, Android Studio, `.pub-cache`, `.nvm`, SDKMAN and Deno; and recents read
  from Cursor, VSCodium, Insiders and Windsurf as well as stock VS Code.
- `restore` was the only mutating verb with no OS gate. The version is now read
  from `plugin.json` instead of being duplicated in `lib/common.sh`.

- Fixed: an application exception in `data/app-rules.tsv` now actually gates
  removal. `cmai_emit` lowered the displayed verdict to ASK, but
  `cmai_reclaim_one` consulted only the guard, which is path-lexical and
  returns ALLOW for `~/Library/Caches/com.spotify.client`. The row warned that
  removing it deletes music saved for offline listening, and was then removable
  with no confirmation at all -- the exact failure app-rules.tsv was added to
  prevent. A risky rule now requires the same individual confirmation a
  rule-table ASK does. (#2)
- `cmai_app_rule` moved to `lib/common.sh` and carries its own scoping, so the
  scan and the reclaim path cannot drift apart again. The check runs against the
  path the guard resolved, so a symlink cannot sidestep a rule.
- `CMAI_APPRULE_SCOPE` test seam, so the gate is testable without writing into
  the real `~/Library`.

## Unreleased

- Fix: a rule-table `ASK` path could never be reclaimed, even when named alone.
  `apply --ids` with a single id now counts as individual confirmation; a list
  still skips `ASK` rows, and the guard's live-state checks still refuse.
- Fix: a path matched by two catalog rows (an old installer in Downloads) was
  emitted twice under one id and acted on twice. Scans now dedupe by id.

## 0.2.0 - 2026-09-15

- `cmai scan projects`: build and dependency directories inside your own
  projects, discovered across the whole home directory in one pruned traversal.
- Active projects are protected. A running process (collected system-wide with
  one `lsof` call), uncommitted changes, a stash, or recent activity in git or
  an IDE all mark a project active. Dependency directories are refused there;
  build output is still offered but never preselected.
- A git-tracked artifact directory is refused at any age: tracked means source.
- Tiered preselection: 30 days for a pure build cache, 60 for a lockfile-backed
  dependency directory, 120 with only a manifest. Ambiguous names (`build`,
  `dist`, `out`, `target`, `vendor`) are never preselected.
- `.cmaikeep` at a project root, or any ancestor, excludes it permanently.
- Every row carries the exact command that restores it.
- New lint gate: a name rule may not collide with a reserved directory name.
  `ALLOWNAME Library` would have resolved `$HOME/Library` to ALLOW.
- Fixed: `cmai_app_rule` substring-matched every path, so a project under a
  directory named after a vendor had its risk and explanation replaced.

## 0.1.0

First release.

- Safety kernel with default-deny, SIP and immutability checks on both a path
  and its parent, symlink re-verification, iCloud placeholder refusal, and
  verdicts carried in exit codes so a caller cannot ignore them.
- Rule table with explicit deny/allow precedence: a permissive rule wins only
  when strictly more specific, and basename rules can never override a deny.
- Honest measurement: allocated blocks rather than logical size, hardlink
  deduplication by inode, candidate de-nesting, and `df`-verified reclaim
  figures with a noise floor.
- Trash-first removal via `/usr/bin/trash`, with Finder and quarantine
  fallbacks. No `rm` anywhere in the production code.
- Append-only manifest with undo classes, and a conservative restore that never
  overwrites.
- Toolchain collectors for Homebrew, Docker, npm, pnpm, yarn, Go, pip, uv and
  simctl, each measured individually.
- Six skills: clean-mac, clean-space, clean-dev, clean-apps, clean-guard,
  clean-tune.
- `cmai myths`, documenting what the tool refuses to do and why, with sources.
