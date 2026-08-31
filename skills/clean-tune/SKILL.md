---
name: clean-tune
description: Diagnose why a Mac is actually slow, and explain which popular fixes are placebo on current macOS. Reports memory pressure rather than free RAM, swap use, CPU and thermal load, startup impact, Spotlight indexing state and disk headroom. Explains why "run maintenance scripts" is impossible on modern macOS, why purging RAM makes things slower, why deleting logs is harmful and why freeing purgeable space is double counting. Use when someone says their Mac is slow, beachballing, running hot, fans are loud, memory is full, or asks whether they should run maintenance scripts or a Mac cleaner.
argument-hint: "[myths]"
allowed-tools: Bash(*/bin/cmai *), Bash(vm_stat), Bash(memory_pressure*), Bash(sysctl *), Bash(ps *), Bash(pmset *), Bash(mdutil *), Bash(df *), Bash(uptime), Read, Grep, AskUserQuestion
---

# /clean-tune -- why it is actually slow, and what will not help

Someone thinks their Mac is slow and has probably been told a cleaner will fix
it. Your job is to find the real cause and to be straight about the rest. This
skill offers **no memory action and no speed action**, because on current macOS
there is no honest one to offer.

`cmai` is at `${CLAUDE_PLUGIN_ROOT}/bin/cmai`.

## Step 1: Measure memory pressure, not free RAM

```bash
memory_pressure -Q 2>/dev/null || memory_pressure | tail -5
sysctl vm.swapusage
vm_stat | head -1
```

Free RAM is the wrong number and always has been. macOS deliberately fills
unused memory with cache, because empty RAM is wasted RAM. The number that means
anything is **pressure**:

- **Green** - memory is not the problem, however little shows as free.
- **Yellow / red** - real demand. The only fix is quitting whatever is
  responsible, which no cleaner can do for you.

Read the page size from `vm_stat`'s own header rather than assuming; it is
16384 bytes on Apple Silicon and 4096 on Intel.

High swap use with green pressure usually just means the machine has been up a
long time. A reboot returns it. That is the whole intervention.

## Step 2: Find what is actually consuming the machine

```bash
ps -Aro pid,pcpu,pmem,comm | head -12
pmset -g thermlog 2>/dev/null | tail -5
uptime
```

Name the top consumers. A single runaway process explains far more slowdowns
than accumulated "junk" ever does.

## Step 3: Startup load

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan agents --lens startup --json
```

Boot and login time is one place where removing things genuinely helps. Orphaned
launch agents pointing at deleted binaries are pure overhead. Hand anything
actionable to `/clean-guard`.

## Step 4: Disk headroom

```bash
df -h /System/Volumes/Data
mdutil -s /
```

Below roughly 10% free, macOS genuinely slows down. That is a real cause, and
`/clean-space` or `/clean-dev` is the fix. If Spotlight is mid-reindex, that
explains both CPU and disk load, and it will finish on its own.

## Step 5: Address the myths directly

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" myths
```

Do this proactively. The user has probably read marketing that promised these,
and they deserve to know why this tool will not do them:

- **"Run maintenance scripts"** - the `periodic` system no longer exists on
  macOS. `/etc/periodic` and `/usr/sbin/periodic` are gone. Any product still
  offering this button cannot be running anything. Verify it live: `ls /etc/periodic`.
- **"Free up RAM"** - `purge` discards the cache macOS deliberately built. The
  next minute is slower, not faster. It is a benchmarking tool.
- **"Delete system logs"** - `logd` rotates them itself and they are size-capped.
  They are the evidence needed to diagnose the very problem being complained
  about.
- **"Free purgeable space"** - the free space macOS reports already includes it.
- **"Repair disk permissions"** - Apple removed system permission repair in
  OS X 10.11.
- **"Reindex Spotlight to speed things up"** - hours of CPU and degraded search.
  A fix for broken search, not a tune-up.

Deliver this as information, not a lecture. One line each is enough unless asked.

## Step 6: Say what would actually help

Rank by measured evidence from the steps above. Usually one of:

1. Quit or fix the specific process burning CPU or memory.
2. Reboot, if swap is large and uptime is long.
3. Free real disk space, if below ~10%.
4. Remove orphaned startup items, if login is slow.
5. Nothing - the machine is fine and the slowness is elsewhere. This is a
   legitimate finding and worth saying.

## What this does NOT do

- **No `purge`, no "free RAM" button.** There is no honest one.
- **No `periodic`.** It does not exist.
- **No log deletion.**
- **No Spotlight reindex** unless search is demonstrably broken, and then only
  with the cost stated up front.
- **No permission repair.** Obsolete since 2015.
- **No `defaults write` tweaks.** Undocumented settings are not performance work.

## Rules

1. **Pressure, not free RAM.** Every time.
2. **Measure before recommending.** Never guess at a cause.
3. **"Your Mac is fine" is a valid answer.** Say it when it is true.
4. **Debunk with evidence and a source**, briefly, without condescension.
5. **Never offer an action you cannot justify.** That restraint is the product.
