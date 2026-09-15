# Changelog

## Unreleased

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
