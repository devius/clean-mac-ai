# Per-project build and dependency directories

`cmai scan projects` finds the `node_modules`, `.venv`, `target`, `build`,
`dist`, `.next`, `.dart_tool` and `Pods` directories inside your own projects.
It is separate from `cmai scan dev`, which reclaims the global toolchain caches
that live at fixed paths.

Two guarantees shape everything below: it does not touch a project you are
actively working on, and it never deletes source.

## The three verdicts

| Verdict | Meaning |
|---|---|
| `INFO` | Protected. Reported so you can see where the space went, never actionable. |
| `ASK` | Offered. Shown with its size and reasoning, but never selected for you. |
| `ALLOW` | Preselected. Idle, unambiguous, over the size floor, and no veto fired. |

These are the same three verdicts the safety kernel uses everywhere else, so
nothing new has to be learned to read the output.

## What protects a directory

Checked in order; the first match wins.

1. **The rule table refuses it.** Everything goes through `guard_path` first.
2. **A `.cmaikeep` marker** at the project root or any ancestor beneath `$HOME`.
3. **It is tracked in git.** A tracked directory is source, not output. Go and
   PHP projects commit `vendor/` deliberately; libraries commit `dist/`. This is
   refused at any age and no flag overrides it.
4. **A process is running inside it.** Collected once for the whole machine with
   `lsof -d cwd`, which takes about a quarter of a second. A dev server running
   in a project is the most direct evidence there is that the project is in use.
5. **It was written to in the last 24 hours** — a build is probably in progress.
6. **It is a dependency directory in an active project.** `--include-active`
   relaxes this to `ASK`; it can never reach `ALLOW`.

## Dependencies versus build output

The distinction that makes the active-project rule useful.

- **`deps`** — `node_modules`, `.venv`, `venv`, `Pods`, `vendor`, `deps`,
  `Carthage`. Restoring one means a reinstall: network, time, and a chance the
  resolved versions differ. **Protected while a project is active.**
- **`build` / `cache`** — `.next`, `.nuxt`, `.svelte-kit`, `build`, `dist`,
  `.dart_tool`, `.gradle`, `target`, `cmake-build-*`, `DerivedData`. Regenerated
  from source alone, with no network. **Offered even in an active project**, but
  never preselected, because the cost is a slower next build.

## Tiers and thresholds

Preselection requires the project to have been idle for longer than its tier.

| Tier | Idle days | What it is |
|---|---|---|
| T3 | 30 | Pure derived cache. Nothing but source is needed to rebuild it. |
| T1 | 60 | Lockfile present, so the restore is pinned and reproducible. |
| T2 | 120 | Manifest only. It will come back, but versions may drift. |

A T1 row whose lockfile is missing is recomputed as T2 — "regenerable" and
"reproducible" are not the same claim, and the longer threshold reflects that.

Minimum size is 50 MB. Below that the reinstall costs more than the space is
worth, and a 400-row list is where mis-clicks happen.

## Ambiguous names

`build`, `dist`, `out`, `target`, `vendor`, `venv`, `deps`, `_build` and `obj`
are also used for hand-written source. They are **never preselected at any age**,
and in the rule table they carry `ASKNAME` rather than `ALLOWNAME`, so the guard
itself can never return `ALLOW` for them. The scanner's logic and the guard's
rules both have to agree before anything is ticked.

Where a marker file settles the question it is reported: a `build/` containing
`CMakeCache.txt` reads `inmarker=ok`, one without reads `inmarker=missing`.

Two names get no rule at all:

- **`Library`** — Unity's import cache. `ALLOWNAME Library` resolves
  `$HOME/Library` itself to `ALLOW`, because no deny prefix covers it and a
  name rule's length-0 score still beats a non-match. Verified against the live
  rule table. `tests/lint.sh` gate 8b rejects it, along with every other
  reserved directory name.
- **`bin`** — technically safe, but `bin/` holds hand-written scripts in a large
  fraction of repositories.

## How idle time is measured

`last_touch` is the **maximum** of every available signal, which biases toward
"active" — the safe direction.

- last commit (`git log -1 --format=%ct`)
- `.git/logs/HEAD` mtime — catches checkouts, rebases and branch switches, which
  a commit date misses entirely
- JetBrains `activationTimestamp`, a real per-project timestamp
- VS Code recents — membership only; that store carries no timestamps, and
  deriving a date from a rank would be an invented number
- manifest and lockfile mtimes at the project root

Two signals are deliberately **not** used. `.git/index` is refreshed by any IDE
or shell prompt running `git status` in the background; measured here it read 0
days old for repositories whose last commit was 53 and 195 days ago. And `atime`
is not updated on read on APFS at all, so "last accessed" would be fiction.

Unpushed commits are reported but do **not** suppress preselection: they live in
`.git` and are not endangered by removing regenerable output, and treating "no
upstream" as a veto would permanently disqualify every local-only repository.

## Excluding a project

Put an empty `.cmaikeep` at its root:

```bash
touch ~/work/client-project/.cmaikeep
```

It protects that project and everything beneath it, so one marker at the top of
a clients directory covers all of them. Because it lives in the repository it
travels with the project and protects teammates too.

It is excluded from the uncommitted-changes check, so adding one does not itself
mark the repository dirty.

## What is never scanned

Top-level dotted directories under `$HOME`, plus `~/go`, `~/Library`,
`~/Applications`, `~/.Trash`, iCloud Drive, application and media bundles, and
every path `catalog-dev.tsv` claims.

This matters more than it sounds. Scanning the home directory without it found
1055 candidates, of which **891 were installed software**: `dist` directories
inside VS Code extensions, a compiled Neovim plugin's `target`, `node_modules`
in the npx cache, and `build` directories inside the read-only Go module cache.
Deleting any of them breaks working software. After filtering, 164 remained.

An artifact also has to sit next to a real project — a `.git` directory or a
recognised manifest — before it is considered at all.
