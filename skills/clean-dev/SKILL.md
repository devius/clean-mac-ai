---
name: clean-dev
description: Reclaim disk space from developer toolchains and from build directories inside your own projects. Runs each tool's own garbage collector rather than deleting files - Homebrew, npm, pnpm, yarn, Go module and build caches, Cargo, Docker and OrbStack, Xcode DerivedData, simulators, Gradle, Maven, CocoaPods, pip and uv. Separately finds node_modules, .venv, target, build, dist, .next, .dart_tool and Pods inside projects, and refuses to touch anything in a project you are actively working on. Use when a developer is out of disk space, or mentions Docker, node_modules, DerivedData, Xcode, Gradle, the Go module cache, or dev caches eating their drive.
argument-hint: "[tool]"
allowed-tools: Bash(*/bin/cmai *), Bash(docker system df*), Bash(brew *), Bash(git *), Read, Glob, Grep, AskUserQuestion
---

# /clean-dev -- developer junk, reclaimed the way each tool intends

You are a developer helping another developer get their disk back. On a working
machine this is almost always the largest and safest win available: toolchain
caches are, by definition, regenerable.

`cmai` is at `${CLAUDE_PLUGIN_ROOT}/bin/cmai`. Never construct `rm`, `mv`,
`sudo` or `find -delete` yourself.

## The rule that matters

**Prefer the tool's own collector over deleting files, always.** `brew cleanup`
beats removing `~/Library/Caches/Homebrew`. `docker builder prune` beats going
anywhere near a disk image. The tool's maintainers decide what is safe to drop,
it understands its own layout, and it cannot be misled by a symlink.

This is not theoretical. CleanMyMac deleted Homebrew's cache *directory* instead
of its contents and broke `brew doctor` for users until Homebrew patched itself
to recreate the directory (Homebrew/brew#5083). `cmai` enforces the distinction
structurally: contents-only rules can never remove the directory they name.

## Step 1: Scan

Two separate scans, because they reclaim different things in different ways.

**Global toolchain caches** - shared across every project on the machine:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan dev --json
```

**Per-project build and dependency directories** - the `node_modules`, `.venv`,
`target`, `build` and `.next` inside your own projects:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan projects --json
```

The project scan walks your whole home directory, so it takes around 20 seconds.
It is worth it: on a working machine this is usually the larger of the two.

Records with `method` starting `gc:` are reclaimed by a collector. Records with
`method` `trash` are moved to the Trash and are recoverable.

Docker is asked directly rather than measured from disk - `docker system df`
knows what is actually reclaimable, and its disk images must never be touched by
a file scanner.

## Step 2: Rank by what it actually costs to regenerate

Present findings grouped by regeneration cost, because that is the real decision:

- **Free to regenerate** - build caches (`go clean -cache`, DerivedData). CPU only.
- **Costs bandwidth** - package caches (npm, Homebrew, Go modules, Gradle,
  Maven). Re-downloaded on next use.
- **Costs a rebuild** - Docker build cache. The next build is cold.
- **Judgement needed** - `project-build` entries. These are `node_modules`,
  `target`, `.venv` and similar in specific projects.

## How the project scan decides

Three verdicts, and they mean exactly what the rest of the tool means by them.

**`INFO` - protected.** Shown so you know where the space went, never actionable.
A directory is protected when a process is running inside it, when it is tracked
in git (that makes it source, not output), when a `.cmaikeep` marker covers it,
when something wrote to it in the last day, or when it is a **dependency**
directory in a project you are actively working on. That last rule is the point
of the split: deleting `node_modules` from a project you are mid-sprint on costs
you a reinstall, so it is refused; deleting that same project's `.next` costs
only a rebuild, so it is offered.

**`ASK` - offered, never selected for you.** Ambiguous names (`build`, `dist`,
`out`, `target`, `vendor`) are always here regardless of age, because those
names are also used for hand-written source. Build output in an active project
is here too, along with anything in a repository with uncommitted changes or
stashes.

**`ALLOW` - preselected.** Unambiguous, over 50 MB, no veto, and idle past its
tier: 30 days for a pure build cache, 60 for a dependency directory with a
lockfile, 120 for one with only a manifest, since the versions that come back
may differ.

Idle time is the **maximum** of every signal available: last commit,
`.git/logs/HEAD`, JetBrains project activation, VS Code recents, and manifest
mtimes. Taking the maximum biases toward "active", which is the safe direction.
`.git/index` is deliberately ignored - any IDE running `git status` in the
background refreshes it, which made every project look active.

Every row carries the exact command that restores it. Read that aloud when you
present a candidate; it is what makes the deletion reversible in practice.

To protect a project permanently, put an empty `.cmaikeep` file at its root. It
also protects everything beneath it, so one marker can cover a whole clients
directory.

## Step 3: Confirm, then reclaim

Ask which categories to reclaim. Never batch-approve anything with `verdict`
`ASK` - `.venv` and `target` are deliberately in that class because those names
are ambiguous enough to be worth a moment's thought.

Toolchain collectors:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" gc docker           # preview
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" gc docker --apply   # run it
```

Targets: `brew docker npm pnpm yarn go pip uv simctl all`.

File-based candidates, by id from the scan:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" apply --ids a3f19c2b7e04,7c1d9048ab55 --apply
```

For project artifacts, add `--from projects` so only that scan is re-run to
resolve the ids rather than all of them:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" apply --ids <ids> --from projects --apply
```

Each collector is timed with a `df` sample around it, so the report says what
each one actually returned rather than what it claimed.

## Step 4: Report honestly

Give the measured delta, not the sum of estimates. If they disagree - and they
will - explain which of the three reasons applies: items are in the Trash and
still occupy space, local snapshots are pinning blocks, or APFS clones were
sharing storage that a directory total counted twice.

**Collector runs cannot be undone.** `brew cleanup`, `docker builder prune` and
`go clean -modcache` remove data that is re-downloadable but not restorable. Say
so before running them, not after.

## What this does NOT touch

- **Docker and OrbStack VM disk images** in `~/Library/Containers` and
  `~/Library/Group Containers`. On a typical machine this is the single largest
  directory in `~/Library`, and it is live storage for running VMs. Reclaim it
  through `docker`/`orb` commands or not at all.
- **`~/Library/Developer/Xcode/Archives`** - the dSYMs for builds you shipped.
  Without them, crash reports from real users can never be symbolicated.
- **The active Xcode toolchain** (`xcode-select -p`).
- **Live simulators.** Only `simctl delete unavailable` is offered, which removes
  runtimes macOS itself has already marked unusable.
- **Source directories.** Only build outputs and caches are candidates, and
  anything tracked in git is refused outright as source.
- **Projects you are working in.** A running dev server, uncommitted changes or
  a stash all protect a project's dependencies.
- **Anything under `~/.vscode`, `~/.local`, `~/go` or `~/.npm`.** Those hold
  installed software and global caches; a `dist` inside an installed extension
  is part of that extension.

## Rules

1. **Collector first, deletion second, never a raw removal.**
2. **Empty the cache, keep the directory.** Enforced by the rule table.
3. **Never batch-approve an `ASK` row.** Ambiguous names are in that class
   because `build` and `dist` are also used for source.
4. **Say "irreversible" out loud** before running any collector.
5. **Report the `df` delta**, and explain it when it disagrees with the estimate.
