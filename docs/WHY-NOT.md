# What this tool refuses to do, and why

Most of what commercial Mac cleaners sell either does nothing, or does harm.
This document lists each claim, the verdict, and a source. `cmai myths` prints
the same table.

The short version: **macOS is not a Windows 98 registry.** It cleans up after
itself, it tells you the truth about free space, and the things a cleaner can
safely delete are mostly things it should not bother deleting.

---

## "Run maintenance scripts" -- impossible

The `periodic` system was removed from macOS. Verify it yourself:

```
$ ls /etc/periodic
ls: /etc/periodic: No such file or directory
$ command -v periodic
(nothing)
```

`/etc/periodic`, `/usr/sbin/periodic` and `/etc/defaults/periodic.conf` are all
gone. Any product still offering a "run maintenance scripts" button cannot be
running them.

Even when it existed, the FreeBSD-inherited scripts were largely vestigial on
macOS: rebuilding the `locate` database, rotating `wtmp`, cleaning `/tmp`. The
only one that touched anything a user cared about was the temp file cleanup,
which `logd` and the OS handle now.

## "Free up RAM" -- makes things slower

`purge` is a developer tool for producing a cold cache before a benchmark. It
discards the unified buffer cache that macOS deliberately filled, so the minute
after you run it is slower, not faster.

Free RAM is the wrong number to watch. macOS fills unused memory with cache
because empty RAM is wasted RAM. The meaningful number is **memory pressure**:
green means memory is not your constraint, however little shows as free.
Yellow or red means genuine demand, which only quitting the responsible
application can fix.

MacPaw themselves now restrict this feature to Intel Macs.

Source: <https://trymainspring.com/blog/purge-command-mac>

## "Delete system and user logs" -- harmful

`logd` rotates and size-caps the Unified Log itself. It needs no help. Those
files contain Time Machine records, XProtect malware-scan results and crash
diagnostics: the evidence you need to diagnose the problem that made you install
a cleaner in the first place.

Howard Oakley, who writes the most technically careful macOS analysis available:

> If the housekeeping app you use deletes log files, particularly if those could
> include those of the Unified log, then I'd consider that to be **malicious**,
> and proof that the app's developers don't understand how macOS works.

Source: <https://eclecticlight.co/2025/01/28/please-dont-delete-your-logs/>

`clean-mac-ai` will not delete logs. Crash reports older than 90 days are
offered as an explicitly reviewed category, and nothing else.

## "Free up purgeable space" -- double counting

The free space macOS reports **already includes purgeable space**. "Reclaiming"
it moves a number that was already counted in your favour.

macOS has a dedicated subsystem for this: `CacheDelete`, driven by the `deleted`
daemon, which evicts caches, iCloud local copies and snapshots at escalating
urgency as the disk fills.

Source: <https://eclecticlight.co/2023/09/22/will-flushing-caches-free-up-disk-space/>

## "Clear all application caches" -- mostly pointless

A cache is a stored computation. Deleting one costs CPU, battery, network and
latency to rebuild, in exchange for space the system would have reclaimed on its
own under pressure.

Clearing a specific app's cache to fix that app's misbehaviour is legitimate
troubleshooting. Clearing all of them on a schedule is not maintenance.

This tool offers cache removal per application, with that caveat stated, rather
than as a single 8 GB checkbox.

Source: <https://eclecticlight.co/2023/05/03/safe-mode-caches-and-cachedelete/>

## "Strip unused architectures from universal binaries" -- not worth it

Measured on a real application: **228 KB saved from 17.2 MB**, about 1.3%. It
modifies signed application bundles, can break helper tools and frameworks, and
the next update restores everything removed.

Source: <https://eclecticlight.co/2020/07/30/instant-weight-loss-how-to-strip-universal-apps/>

## "Remove unused language files" -- not worth it

Trivial savings on any modern SSD, modifies signed bundles, returns on every
update, and can break applications that enumerate their own localizations.

## "Repair disk permissions" -- obsolete since 2015

Apple removed system-wide permission repair in OS X 10.11. Only
`diskutil resetUserPermissions` remains, and it touches nothing outside your home
directory. Any product still advertising this as a fix is describing a feature
that has not existed for a decade.

## "Reindex Spotlight to speed up your Mac" -- diagnostic only

`mdutil -E` erases the index and forces a rebuild costing hours of CPU, during
which search is degraded. It is a fix for demonstrably broken search, not a
performance improvement.

Source: <https://eclecticlight.co/2024/11/19/when-and-how-to-rebuild-spotlight-indexes/>

## "Delete broken preference files" -- risky

`cfprefsd` holds preferences in memory and writes them back. Deleting plists
behind its back loses settings and can resurrect stale values. Cleaners
routinely misidentify perfectly valid preferences as broken.

## "Clean your Mac to protect against malware" -- unrelated

Deleting caches and preferences has nothing to do with malware defence.
Independent testing of a leading cleaner in 2025 found it missed WaveBrowser and
left parts of AdWind installed.

macOS runs XProtect already. For real coverage use a real anti-malware product,
and Objective-See's KnockKnock and BlockBlock for persistence.

Source: <https://www.macworld.com/article/352922/cleanmymac-x-review-macos.html>

---

## The pattern

Howard Oakley's structural point is the one worth ending on: the mess exists
because applications scatter files outside their bundles, and the fix is for
developers to declare what they install, not for a scanner to guess afterwards.

Heuristic leftover hunting is guesswork by construction. This tool does it too -
that is what `/clean-apps` is - but it defaults to the strictest matching
available, marks anything looser as needing review, and moves rather than
deletes. Guessing is unavoidable; guessing confidently is not.

Source: <https://eclecticlight.co/2025/01/26/last-week-on-my-mac-can-we-make-cleaning-up-our-macs-simpler/>
