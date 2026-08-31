---
name: clean-apps
description: Completely uninstall macOS applications and find leftovers from apps already deleted - containers, preferences, application support, caches, saved state, launch agents, HTTP storages and installer receipts. Matches by bundle identifier with three sensitivity tiers, strict by default. Use when someone wants to uninstall or fully remove an app, delete an application properly, clean up remnants or leftovers from software they removed, or asks about AppCleaner, AppZapper or Pearcleaner.
argument-hint: "[--app /Applications/Name.app] [--tier strict|enhanced|deep]"
allowed-tools: Bash(*/bin/cmai *), Bash(pkgutil *), Bash(codesign *), Bash(pgrep *), Read, Glob, Grep, AskUserQuestion
---

# /clean-apps -- uninstall properly, and find what earlier uninstalls left

Dragging an app to the Trash leaves its preferences, caches, containers and
sometimes its launch agents behind. You are here to remove an application
completely, or to find the debris from ones already gone.

`cmai` is at `${CLAUDE_PLUGIN_ROOT}/bin/cmai`. Never construct `rm`, `mv`,
`sudo` or `find -delete` yourself.

## Step 1: Decide which job this is

**Uninstalling a specific app:**

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan apps --app "/Applications/Name.app" --json
```

**Finding orphans from apps already removed:**

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan apps --json
```

Orphan detection is deliberately conservative: it only claims a directory when
its name is shaped like a bundle identifier *and* no installed application
declares that identifier. That keeps false positives near zero, which matters
because a false positive here deletes someone's data.

## Step 2: Understand the matching tiers

Identifiers are derived from the app the way Pearcleaner does it, and the tier
decides which are allowed to match:

| Tier | Matches on |
|---|---|
| `strict` (default) | exact bundle id, and its last two components |
| `enhanced` | adds the app name with any trailing version stripped |
| `deep` | adds a letters-only reduction of the name |

Start at `strict`. Escalate only when the user says files were clearly missed,
and say what the escalation costs: a looser match means a real chance of
proposing a file that belongs to a different application with a similar name.
Everything above `strict` is marked `review` and can never be batch-approved.

## Step 3: Quit the app first

If the app is running, its files are live. Removing them underneath it corrupts
state at best. The scan flags this in `evidence`; act on it before proposing
anything, and ask the user to quit the app.

## Step 4: Present, confirm, apply

Show the bundle and each leftover with its size and why it matched. Then:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" apply --ids <id,id,...> --apply
```

Everything here goes to the Trash or quarantine, so an uninstall is reversible:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" restore --run <runid> --apply
```

Offer that immediately after an uninstall. It is the difference between a
confident removal and a nervous one.

## Step 5: Receipts

Installer receipts are **reported, never removed**. `/private/var/db/receipts`
is protected, and deleting receipts breaks `pkgutil`, future updates and any MDM
inventory. If the user genuinely needs one gone, hand them the command:

```
sudo pkgutil --forget <package-id>
```

## What this does NOT touch

- **`~/Library/Containers` as a whole.** Only the exact bundle directory for the
  app being removed. A container holds an app's *documents*, not just its cache.
- **`~/Library/Group Containers`.** Shared between whole families of apps, and
  home to live VM disk images. Never removed as part of an uninstall.
- **`/private/var/db/receipts`.** Reported only, as above.
- **System applications.** They are SIP-protected and cannot be removed; the
  scan will say so rather than appearing to try.
- **Anything matched only by a loose name** when the tier is `strict`, which is
  the default for exactly this reason.

## Rules

1. **Strict by default.** Escalate only on request, and explain the trade-off.
2. **Quit before removing.** Live files are not leftovers.
3. **A bundle id is evidence; a similar name is a guess.** Label them differently.
4. **Always offer the restore command** right after an uninstall.
5. **Receipts are reported, never removed.**
