# Safety model

This tool deletes things on your computer. This document explains exactly what
stops it deleting the wrong thing, and is honest about what is not covered.

## The guard

Every candidate path passes through `guard_path()` in `lib/guard.sh` before
anything touches it. `lib/reclaim.sh` is the only file in the project permitted
to mutate the filesystem, and it calls the guard itself rather than trusting its
callers.

The verdict is carried in the **exit code**, deliberately: under `set -e`, a
caller that forgets to check aborts the run instead of silently deleting.

| Code | Verdict | Meaning |
|---|---|---|
| 0 | ALLOW | may act, subject to the run-level approval |
| 10 | ASK | must be confirmed individually; never batch-approved |
| 20 | DENY | hard refusal; no override exists in the tool |

Checks run in this order:

1. **Lexical** - must be absolute, no `..`, no glob metacharacters, no control
   characters. A control character would corrupt the TSV stream and the manifest.
2. **Existence** via lstat, so a dangling symlink is still removable as itself.
3. **Symlink resolution with re-verification.** A symlink is unlinked as itself
   and never followed. Where an ancestor symlink makes the raw and resolved
   forms name different trees, both must pass.
4. **Never `/`, `$HOME`, or a volume mount point.**
5. **Depth floor** - nothing shallower than two components.
6. **SIP and immutability flags, on the target and on its parent.** The parent
   matters: `sunlnk` on a directory is what actually blocks unlinking its
   children, and it is set on `/usr/local`, `/Users` and `/Applications`.
7. **iCloud and dataless placeholders** are refused outright. Deleting a
   placeholder deletes the cloud original on every device and frees nothing
   locally, and merely traversing `~/Library/Mobile Documents` can trigger
   downloads.
8. **Ownership** - anything not owned by the invoking user can never be ALLOW.
9. **The rule table.**
10. **Contents-only enforcement** - a directory marked contents-only can never
    itself be removed.
11. **TCC readability.**
12. **Running-process conflict.**
13. **Root-owned paths return ASK with a printed command.** The tool never
    escalates privileges to delete.

Two floors sit above the guard, because the guard is deliberately path-lexical
and cannot know what an application keeps where:

- **Application exceptions.** A path matching a `risky` rule in
  `data/app-rules.tsv` requires individual confirmation even when the guard
  allows it. Spotify keeps offline downloads under its cache directory, and a
  cleaner that treats that as junk deletes someone's music. The scan and the
  reclaim path call the same `cmai_app_rule`, so what is displayed is what is
  enforced.
- **Risk downgrades from the scan.** `risky` never raises a verdict, only
  lowers it. A DENY is never softened.

**The last line is default-deny.** A path matching no rule is refused. Every
reclaimable location must be explicitly named in `data/denylist.tsv`. Adding a
new category means adding a rule and a test, deliberately.

## Rule precedence

Deny and allow are evaluated independently, then combined:

1. Longest matching `DENY` prefix, or any `DENY` glob.
2. Longest matching permissive prefix (`ALLOW` / `ASK` / `CHILDREN`).
3. A permissive rule wins **only if it is strictly more specific** - a longer
   prefix. No shipped rule relies on this today (`/usr/local` used to, and is now
   denied in its own right), so the branch is covered by a fixture table in
   `tests/test_denylist.sh` — including an equal-length `ALLOW` that must lose.
4. Name rules (`ALLOWNAME` / `ASKNAME`) match a basename anywhere and carry
   length zero, so they can never override any deny. A `node_modules` directory
   inside a protected location stays protected.
5. Nothing matched means deny.

Naive "longest match wins" would be a vulnerability: a glob such as
`*/node_modules` is 15 characters and `/System` is 7.

## Enforced invariants

`tests/lint.sh` fails the build on any of these, as plain greps rather than
review conventions:

- No recursive or forced removal anywhere in `bin/` or `lib/`
- No privilege escalation in `lib/reclaim.sh`, and never on the same line as a removal
- No network client (`curl`, `wget`, `nc`, `ftp`, `scp`, `ssh`) in production code
- bash 3.2 only, because `/bin/bash` on macOS is 3.2.57
- External tools called by absolute path
- Every `DENY` rule has a corresponding test
- shellcheck clean

That last one matters more than it looks. If a user's shell profile defines
`find` as a function - aliasing it to `bfs`, say - then a bare `find` silently
changes behaviour and `-flags` stops working, which would turn the SIP and
dataless checks into no-ops. Every tool is called as `/usr/bin/find`.

## Removal is never deletion

The ladder is: **the toolchain's own collector** → **`/usr/bin/trash`** →
**Finder** → **quarantine inside `CMAI_ROOT`**. There is no fifth tier. `rm`
does not appear in the production code at all.

Paths are re-guarded at the moment of action, not only at scan time. Between a
scan and an approval an application may have launched or a symlink may have been
swapped.

A cross-device move is refused rather than performed: `mv` across volumes is a
full copy, which on a large tree consumes space instead of freeing it.

## Two floors that do not live in the rule table

**Package-manager prefixes are denied on every architecture.** `/usr/local`
(Intel Homebrew), `/opt/homebrew` (Apple Silicon Homebrew) and `/opt/local`
(MacPorts) are all denied by name. Denying `/usr/local` explicitly, rather than
letting it fall through to the `/usr` rule, is what keeps the verdict identical
on both chips: before this, the entire live Homebrew install was `ALLOW` on
Intel and default-denied on Apple Silicon, so default-deny varied with the
hardware. Homebrew chowns those directories to the invoking user, which defeats
the root-ownership `ASK`, and `sunlnk` on `/usr/local` only protects its direct
children.

**The tracked-source check fails closed.** `git ls-files` exiting non-zero means
"not tracked" only when git actually ran. `/usr/bin/git` is a Command Line Tools
stub, so on a Mac without them the same non-zero result would read as "safe to
delete" and the hard stop would silently stop protecting committed code. When
git is unusable, everything inside a repository is therefore treated as tracked.
`preflight` and `doctor` both report git's state, distinguishing absent from
present-but-a-stub.

## What cannot be tested locally

Stated plainly, because a test suite that implies more coverage than it has is
worse than none:

1. **SIP `restricted` refusal.** The flag cannot be set on a fixture; only the
   OS sets it. The test asserts against real `/System` and `/usr`, which is a
   read-only check of the live system rather than a fixture.
2. **`sunlnk` on a fixture parent.** Setting `sunlnk` requires root. The test
   asserts against `/usr/local`, which carries it on stock macOS.
3. **Dataless file handling.** Creating one requires an iCloud account, network
   eviction and hours of waiting. The `-flags +dataless` predicate is verified to
   parse and run; the skip behaviour is not covered. **This is a known gap.**
4. **Whether `trash(8)` works under a given TCC state.** This cannot be
   determined by inspection - it differs per host application. So it is
   *measured* instead: `cmai preflight` creates a zero-byte probe file, trashes
   it, and records the result, choosing the backend from what actually happened.
   An untestable assumption became a runtime-measured fact.
5. **A full real-disk apply run.** No automated test performs one.

## The Full Disk Access trade-off

Terminals frequently lack Full Disk Access, in which case some locations report
as unreadable rather than being silently skipped.

Before granting it, understand the cost: **Full Disk Access granted to a
terminal is inherited by every process that terminal launches**, for as long as
it is granted. That is a broad concession for a cleanup tool.

Measured on macOS 26, `/usr/bin/trash` works *without* Full Disk Access, so in
practice the trade-off rarely needs to be made at all.

## Reporting a problem

If you find a path this tool proposes that it should not, that is a security
bug. Open an issue with the `evidence` line from the scan. A missing rule is a
one-line fix to `data/denylist.tsv` plus a test.
