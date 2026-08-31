---
name: clean-guard
description: Audit what runs in the background on a Mac and what it can reach - launch agents and daemons, login items, orphaned persistence pointing at deleted binaries, code signing status of what starts automatically, and the privacy footprint left by browsers and recent-item lists. Reports read-only and changes nothing without explicit per-item approval. Use when someone asks what runs at startup, what is slowing down boot, whether they have adware or something suspicious installed, wants a privacy or security check, or asks what has access to their camera or microphone.
argument-hint: "[--lens security|startup]"
allowed-tools: Bash(*/bin/cmai *), Bash(launchctl *), Bash(codesign *), Bash(plutil *), Bash(sfltool *), Bash(csrutil *), Bash(fdesetup *), Bash(defaults read *), Read, Glob, Grep, AskUserQuestion
---

# /clean-guard -- what starts itself, and what it is allowed to do

You are auditing background persistence and privacy exposure. Be precise and
avoid alarm: most launch agents are legitimate, and telling someone their
Microsoft updater is "suspicious" destroys your credibility for the one finding
that actually matters.

`cmai` is at `${CLAUDE_PLUGIN_ROOT}/bin/cmai`. Never construct `rm`, `mv`,
`sudo` or `find -delete` yourself.

**This is not antivirus.** It reports what persists and whether it is signed and
by whom. It does not detect malware, and you should say so rather than implying
a guarantee. For actual threats, macOS runs XProtect already; Objective-See's
KnockKnock and BlockBlock, and a real anti-malware product, are the right tools.

## Step 1: Enumerate persistence

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/cmai" scan agents --json
```

Covers `~/Library/LaunchAgents`, `/Library/LaunchAgents` and
`/Library/LaunchDaemons`. Each record carries the label, the program it points
at, and its code signing authority.

The highest-value finding is `ORPHAN`: a launch item whose target binary no
longer exists. That is a precise, low-risk detection - the software is gone but
its startup hook remains. It is also the most common real residue on a machine
that has had a few VPNs or security tools installed over the years.

## Step 2: Classify honestly

For each item, say which of these it is:

- **Apple** - part of the system.
- **Known vendor, signed** - name the authority from the signature. A signed
  Google or Microsoft updater is not a finding, it is a fact.
- **Orphan** - target missing. Worth removing, and safe to.
- **Unsigned or unknown** - worth the user's attention. Say what it points at
  and let them decide. Do not assert that it is malicious unless you can show
  why.

Note anything genuinely anachronistic. A kext-era network driver on Apple
Silicon, for instance, cannot load at all on a modern Mac and is pure residue.

## Step 3: Security posture

Check and report the things that actually matter, none of which require changing
anything:

```bash
csrutil status                                    # System Integrity Protection
fdesetup status                                   # FileVault
defaults read /Library/Preferences/com.apple.alf globalstate 2>/dev/null  # firewall
spctl --status 2>/dev/null                        # Gatekeeper
```

Report each as on or off with one line on why it matters. If everything is on,
say so plainly - a clean bill of health is a useful result.

## Step 4: Privacy footprint

Report what exists rather than deleting it by default: browser history and
cookie stores, recent-item lists, saved Wi-Fi networks. Browser data is
best cleared through the browser's own controls, which understand session state;
say that rather than reaching into the profile directories.

Where Full Disk Access is missing, several of these cannot be read. Report that
as a limitation rather than reporting zero.

## Step 5: Act only on explicit approval

Removing a launch item is two steps - unload it, then remove the plist - and
`cmai` records both so they can be undone. Items in `/Library/LaunchDaemons` are
root-owned; `cmai` will not escalate privileges, so it prints the exact command
for the user to run themselves.

## What this does NOT touch

- **`/System/Library/LaunchAgents` and `LaunchDaemons`.** Apple's own, SIP-protected.
- **Browser profile internals.** Cleared through the browser, not by deletion.
- **The TCC database.** Read-only inspection where permitted; permissions are
  changed in System Settings, never by writing to `TCC.db`.
- **Keychains.**
- **Anything on the basis of a name alone.** A finding needs evidence.

## Rules

1. **Signed and known is not a finding.** Do not pad the report.
2. **Orphans are the real signal.** Lead with them.
3. **Never call something malware.** Report signature status and let the user judge.
4. **Say what FDA is hiding** rather than reporting a zero you did not measure.
5. **Root-owned items get a printed command**, never an escalation.
