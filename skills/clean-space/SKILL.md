---
name: clean-space
description: Find and reclaim general disk space on macOS - per-application caches, stale downloads, leftover installer disk images and packages, Trash contents, saved application state, and large files that have not been opened in months. Scans read-only with true APFS allocated sizes, then moves only approved items to the Trash. Use when someone asks what is taking up space, says their disk or startup disk is full, wants to find large or old files, or wants to clear caches. Developer caches belong to clean-dev instead.
argument-hint: "[--min 500M] [--older-than 180]"
allowed-tools: Bash(*/bin/cmai *), Bash(df *), Bash(du *), Read, Glob, Grep, AskUserQuestion
---

# /clean-space -- general disk space, judged per item

You are helping someone reclaim space from the ordinary parts of their Mac. Be
skeptical of your own findings: the reason commercial cleaners have a poor
reputation is that they present regenerable caches and irreplaceable user data
in the same list with the same checkbox.

`cmai` is at `${CLAUDE_PLUGIN_ROOT}/bin/cmai`. Never construct `rm`, `mv`,
`sudo` or `find -delete` yourself.

## Step 1: Scan

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan space --json
```

Every candidate is a single item, never a whole directory. `~/Library/Caches` is
offered as one row per application, because the decision is per application: one
of those directories is a browser's font cache and another is a music app's
offline library.

For large files:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan large --min 500M --older-than 180 --json
```

## Step 2: Read the risk column before the size column

- `safe` - regenerable, no user data.
- `review` - probably fine, but it is the user's data or the user's decision.
- `risky` - an application exception fired. Something here is real user data
  despite living under a name like "cache". Read the `evidence` sentence aloud
  to the user; it says exactly what would be lost.

The `risky` class exists because of specific documented failures. Spotify keeps
offline downloads inside its cache directory, and cleaners have proposed
deleting users' entire saved music as "cache". Never let a `risky` item be
approved as part of a batch.

## Step 3: Be honest about caches

Before proposing a cache clean, say plainly what it buys:

macOS already reclaims caches on its own. The `CacheDelete` subsystem evicts
them automatically under real disk pressure, and the free space `df` reports
already includes purgeable space. Deleting a cache trades a slower next launch
for space the system would have returned anyway. It is a reasonable thing to do
when a specific application is misbehaving, or when the disk is genuinely full
right now. It is not routine maintenance, and anyone selling it as such is
selling a number rather than a benefit.

If the user still wants it, do it. Just do not let them believe it is more than
it is.

## Step 4: Confirm and apply

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" apply --ids <id,id,...>            # preview
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" apply --ids <id,id,...> --apply    # do it
```

A list of ids is a batch, and `ASK` rows in a batch are skipped. Apply each
approved `ASK` row on its own, one id per call.

Then report the measured result and, if anything was trashed, tell the user
plainly that the space returns when they empty the Trash - not before.

## What this does NOT touch

- **Logs**, anywhere. Not `~/Library/Logs`, not `/var/log`, not the Unified Log.
  `logd` manages them, they are size-capped already, and they are what you need
  to diagnose problems. Crash reports older than 90 days are offered separately
  and marked `review`.
- **Language files, universal binary slices, "broken" preferences.** All three
  are classic cleaner features. All three modify signed bundles or live state
  for savings measured in single-digit megabytes. See `cmai myths`.
- **iOS device backups.** Shown so you know where the space is; never removable
  here.
- **iCloud placeholders**, `~/Library/Group Containers`, Photos and Music
  library bundles, Mail storage, Keychains.

## Rules

1. **One item, one decision.** Never a directory as a single checkbox.
2. **Read `evidence` before proposing anything.** It is written for the user.
3. **`risky` is never batch-approved.**
4. **Large files are shown, never selected.** That is someone's work.
5. **Trashing is not freeing.** Say it every time.
