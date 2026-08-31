# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin that reclaims macOS disk space. It replicates the useful
parts of CleanMyMac and deliberately refuses the rest — `docs/WHY-NOT.md` and
`data/myths.tsv` document each refusal with a source, and that stance is a
product requirement, not commentary. Do not add a feature listed there.

Pure bash 3.2 plus system tools. No Python, Node, or Homebrew dependency.

## Commands

```bash
tests/run.sh                        # lint + every test (this is the gate)
tests/lint.sh                       # invariants + shellcheck only
tests/test_guard.sh                 # a single suite; each test_*.sh runs standalone
tests/mkproj.sh                     # project fixtures; backdates artifacts AND manifests,
                                    # or every fixture reads as active

CMAI_I_UNDERSTAND=yes tests/soak.sh # end-to-end against the REAL Trash; opt-in

./bin/cmai preflight                # what this machine permits
./bin/cmai doctor                   # self-check; guard must refuse /, /System, /usr, $HOME
./bin/cmai scan all --json          # read-only
./bin/cmai scan projects            # per-project artifacts (~20s, walks $HOME)
./bin/cmai apply --ids a3f,7c1      # dry-run; add --apply to act
./bin/cmai gc docker --apply        # a toolchain's own collector
./bin/cmai restore --run <runid> --apply
```

`brew install shellcheck` — lint skips it when absent, CI does not.

Test sandbox knobs, honored by `lib/common.sh`: `CMAI_ROOT` (manifest and
quarantine), `CMAI_DENYLIST` (rule table), `CMAI_TRASH_BACKEND=quarantine`,
`CMAI_DRY_RUN`, `CMAI_SKIP_OS_GATE` (CI only). `tests/test_reclaim.sh` overrides
the first three, which is why it can safely exercise deletion.

## Architecture

`bin/cmai` is the only entry point. It sources every `lib/*.sh` and dispatches
on a verb. Skills are thin prompts that call it and reason over its output; they
never construct shell commands themselves. The single-dispatcher shape exists so
the safety kernel cannot be bypassed — `lib/reclaim.sh` is the only file allowed
to mutate the filesystem, and it calls `guard_path` itself rather than trusting
callers.

### The safety kernel

`lib/guard.sh` → `guard_path <abs_path>` gates everything. It **carries its
verdict in the exit code** (0 ALLOW / 10 ASK / 20 DENY) so that under `set -e` a
caller who forgets to check aborts instead of silently deleting. stdout is one
TSV line: `MODE, RULE, REASON, RESOLVED, NEEDS`.

**Default-deny is the core property.** A path matching no rule is refused, so
enabling a new location is a two-key operation:

1. add it to `data/catalog-space.tsv` or `catalog-dev.tsv` (proposes it), and
2. add a rule to `data/denylist.tsv` (permits it), and
3. add a test — `tests/lint.sh` fails the build if a `DENY` rule has no case in
   `tests/cases-guard.tsv` or `tests/test_denylist.sh`.

### Per-project artifacts (`lib/scan_projects.sh`)

`cmai scan projects` is separate from `scan dev`: the latter reclaims global
tool caches at fixed paths, the former finds artifacts inside the user's own
projects anywhere under `$HOME`. `data/catalog-projects.tsv` is its taxonomy.

Three things are load-bearing and non-obvious:

- **Discovery is one traversal.** Exclusions are pruned first without printing;
  markers are `-print0 -prune`, so a marker is emitted *and* not descended.
  Adding `node_modules` to the marker group makes the scan faster, not slower,
  because the walk stops at the top of the biggest trees. A per-marker loop
  finds 1744 `dist` directories where only 36 are real.
- **Two filters, both required.** Skip dotted directories directly under `$HOME`
  plus every `catalog-dev.tsv` path (`~/go` is not a dotdir), then require a
  manifest or `.git` beside the artifact. Without them the scan reports
  installed software: 891 of 1055 candidates here were VS Code extensions,
  Neovim plugins and the Go module cache.
- **`deps` versus `build`/`cache` decides the active-project rule.** A
  dependency directory in an active project is refused because restoring it
  costs a reinstall; build output is still offered because it costs a rebuild.

Verdicts reuse the guard's vocabulary exactly: `ALLOW` preselect, `ASK` offered,
`INFO` reported but never actionable. Protected rows pass `floor=info` to
`cmai_emit`, which may only ever weaken a verdict.

Activity signals worth knowing: `.git/index` is **not** used (an IDE running
`git status` refreshes it, so it read 0 days for repos last committed 53 and 195
days ago); `atime` is not updated on read on APFS; unpushed commits are reported
but do not veto, since they live in `.git` and are not at risk from deleting
build output.

### Rule precedence (`lib/denylist.sh`)

Deny and allow are evaluated **independently**, then combined. A permissive rule
wins only when it is a *strictly longer prefix* than the matching deny — that is
what carves `/usr/local` out of `/usr`. Naive "longest match wins" would be a
vulnerability, since `*/node_modules` is 15 characters and `/System` is 7.

`ALLOWNAME`/`ASKNAME` match a basename anywhere and carry length 0, so they can
never override a deny; a `node_modules` inside a protected tree stays protected.

**A name rule must never use a reserved directory name.** `ALLOWNAME Library`
resolves `$HOME/Library` itself to `ALLOW` — no deny prefix covers it, and
length 0 still beats a non-match of -1. Verified against the live table. Lint
gate 8b rejects that and every other reserved name, and requires each name rule
to have a case in `cases-guard.tsv` or `test_denylist.sh`. Gate 8 only covers
`DENY` rules, so without 8b the whole permissive surface is ungated.

`CHILDREN` (contents-only) applies to the directory the rule *names exactly*.
Below it the mode is `self`, otherwise every child would be judged a directory
that must be preserved and nothing could be removed. This encodes
Homebrew/brew#5083, where a cleaner removed the cache directory instead of
emptying it.

### Measurement discipline (`lib/measure.sh`, `lib/report.sh`)

Three numbers, never conflated: `candidate_bytes` (allocated blocks via
`stat %b`, hardlink-deduped by inode+device, dataless excluded),
`pending_bytes` (moved but still occupying space), and `reclaimed_bytes` (the
measured `df` delta).

**Moving to the Trash does not free space.** `report.sh` says so explicitly and
explains a near-zero delta via the three real causes: items still in the Trash,
local Time Machine snapshots pinning blocks, or APFS clone sharing. Never
"simplify" this into a single freed figure — the honesty of that distinction is
the product.

### Scan contract

TSV is the wire format; `--json` materializes it with `jq -R`. This is not
because `jq` might be missing (macOS ships it) but because hand-escaping
arbitrary macOS filenames from bash is how a malformed record ends up naming the
wrong path. `guard_path` rejects tabs and control characters, so TSV is safe to
build and `jq` does the encoding.

Each record's `evidence` field is prose written for a human — it is what the
skills reason over, so keep it specific and explanatory.

## Constraints that will bite you

- **bash 3.2.** `/bin/bash` on macOS is 3.2.57. No associative arrays, no
  `mapfile`, no `${x,,}`. Lookup tables are TSV plus `awk`.
- **Absolute tool paths, always** (`$FIND`, `$STAT`, … from `lib/common.sh`). A
  user profile defining `find` as a function silently changes behaviour and
  `-flags` stops working, which would turn the SIP and dataless checks into
  no-ops. Lint enforces this.
- **No `case` inside `$(...)`.** bash 3.2 reads the `)` closing each pattern as
  the end of the substitution. `_cmai_scan_run` and `_cmai_gc_run` exist purely
  to keep their `case` outside a substitution.
- **No `producer | grep -q`.** Under `pipefail`, grep exits on first match, the
  producer dies of SIGPIPE, and the pipeline returns 141 — a successful match
  reads as a failure, which in a safety check inverts a refusal into a pass. Use
  `[ -n "$(...)" ]`. Lint gate 6b rejects the pattern.
- **Flags are checked on a path *and its parent*.** `sunlnk` on the parent is
  what actually blocks unlink, and it is set on `/usr/local`, `/Users` and
  `/Applications`.
- Comments in `bin/` and `lib/` must not contain the strings the lint greps for
  (`sudo`, `rm -rf`, `curl`). The gates are deliberately dumb so they cannot be
  argued with; reword the comment instead of weakening the check.

## Invariants enforced by `tests/lint.sh`

No `rm -r/-f/-rf` in `bin/` or `lib/`; no privilege escalation in
`lib/reclaim.sh` or on any line with a removal; no network client anywhere in
production code; bash 3.2 only; absolute tool paths; every deny rule tested;
shellcheck clean. Suppressions live in `.shellcheckrc`, each with a reason.

Removal ladder, in order, with no fifth tier: **toolchain collector → `/usr/bin/trash`
→ Finder → quarantine under `CMAI_ROOT`**. Prefer a tool's own collector over
deleting files wherever one exists.

## Testing notes

`tests/cases-guard.tsv` is the highest-value file in the repo — a golden table
of `path, expect_exit, expect_mode, expect_rule_prefix`.

Fixtures live under `$TMPDIR`, which resolves inside `/private/var/folders` and
is therefore **denied by the real rule table**. That is correct behaviour, and it
is why `tests/test_reclaim.sh` must override `CMAI_DENYLIST` with a
sandbox-scoped table rather than relying on a temp directory.

`docs/SAFETY.md` lists what genuinely cannot be tested locally (SIP `restricted`,
`sunlnk` on a fixture, dataless files, `trash(8)` under a given TCC state). Keep
that list honest rather than implying coverage that does not exist. The
`trash(8)` case is handled by measuring instead: `cmai preflight` trashes a
zero-byte probe file and picks the backend from what actually happened.

## Supported platform

macOS 15+ (`/usr/bin/trash` and `/usr/bin/jq` both arrived in 15). `preflight`
hard-fails below that. Developed and verified against macOS 26.6.2 on Apple
Silicon. Full Disk Access is not required — `trash(8)` works without it.
