# clean-mac-ai

**An honest Mac cleaner for Claude Code.**

Most Mac cleaning software sells maintenance theater. This one measures what is
actually there, reclaims it the way each tool intends, tells you the truth about
what it freed, and refuses to do the things that do not work.

```
/plugin marketplace add davidmachakhelidze/clean-mac-ai
/plugin install clean-mac-ai
```

Then, in Claude Code:

```
/clean-mac
```

---

## Why another one

While researching what CleanMyMac actually does, three things became hard to
ignore.

**Its headline maintenance feature is impossible.** "Run maintenance scripts"
invokes `periodic`, which no longer exists on macOS:

```
$ ls /etc/periodic
ls: /etc/periodic: No such file or directory
```

**Its most-advertised features are counterproductive.** "Free up RAM" runs
`purge`, a benchmarking tool that discards the cache macOS deliberately built,
making the next minute slower. "Free purgeable space" moves a number that `df`
already counts as free. Deleting logs destroys the evidence needed to diagnose
the problem you installed a cleaner to fix.

**Meanwhile the real space is somewhere else entirely.** On the machine this was
built against, the largest single reclaimable item was Docker's build cache at
7.6 GB, recovered by one command. The famous "Xcode eats 100 GB" module found
14 MB.

So this tool is built around a different premise: **find the few places holding
real space, reclaim them with each tool's own garbage collector, verify the
result, and be straight about the rest.**

## What it does

Six skills, each owning one job:

| Skill | Job |
|---|---|
| `/clean-mac` | Where your space went. Scans everything, explains it, routes. Never deletes. |
| `/clean-dev` | Toolchain caches via `brew cleanup`, `docker builder prune`, `go clean`, and friends. Plus per-project `node_modules`, `.venv`, `target`, `build` and `.next` — protected in projects you're actively working on. |
| `/clean-space` | Caches per application, stale downloads, installers, large and long-unused files. |
| `/clean-apps` | Full uninstall with leftovers, and orphans from apps already gone. |
| `/clean-guard` | Launch agents, login items, orphaned persistence, security posture. |
| `/clean-tune` | Why it is actually slow, and which popular fixes are placebo. |

There is also a plain CLI, usable without Claude:

```bash
cmai preflight              # what this machine permits
cmai scan all --json        # find candidates, read-only
cmai scan projects          # build dirs inside your own projects
cmai gc docker --apply      # run a toolchain's own collector
cmai apply --ids a3f,7c1    # reclaim specific items
cmai restore --run <id>     # put it back
cmai myths                  # what this tool refuses to do, with sources
```

## What makes it different

**It tells the truth about what it freed.** Moving files to the Trash does not
free space; the space returns when the Trash is emptied. A tool that trashes
4 GB and reports "4 GB freed" is lying. This one samples `df` before and after
and reports the measured delta, then explains any gap: items still in the Trash,
local Time Machine snapshots pinning blocks, or APFS clones sharing storage.

**It measures honestly.** Sizes use allocated blocks rather than logical length,
so sparse and compressed files are not inflated. Hardlinks are deduplicated by
inode, which matters because npm and pnpm stores are hardlink-heavy. Overlapping
candidates are de-nested before anything is summed. iCloud placeholders are
excluded, and never traversed - walking into them triggers downloads.

**It prefers each tool's own collector.** `brew cleanup` beats deleting
Homebrew's cache directory. That is not a style preference: CleanMyMac deleted
the cache *directory* rather than its contents and broke `brew doctor` until
Homebrew patched itself to recreate it ([Homebrew/brew#5083](https://github.com/Homebrew/brew/issues/5083)).
Contents-only rules here can never remove the directory they name.

**It will not touch a project you're working on.** The per-project scan collects
every running process's working directory in one call, reads JetBrains and VS
Code recents, and takes the *maximum* of every activity signal — so a dev server,
an uncommitted change, or a checkout last week all protect a project. Dependency
directories like `node_modules` are refused outright in an active project because
restoring one costs a reinstall; that same project's `.next` is still offered,
because it costs only a rebuild. A directory tracked in git is refused at any
age, since that makes it source rather than output. Drop an empty `.cmaikeep` in
a project to exclude it permanently.

**It knows your machine, not just your directories.** The scan is input to
reasoning, not the output. Instead of "Caches: 8.5 GB" you get: your
`ms-playwright` cache is 849 MB of browser binaries that re-download on the next
test run; that launch daemon points at a kext-era VPN driver that cannot load on
Apple Silicon and is pure residue.

**Everything is undoable, and it says when it is not.** Every run writes an
append-only manifest classing each action `full`, `rebuildable` or
`irreversible`. Collector runs genuinely cannot be undone, and you are told
before they run, not after.

## Safety

- **Default-deny.** A path matching no rule is refused. Every reclaimable
  location is explicitly listed in `data/denylist.tsv`.
- **No `rm` in the codebase.** Removal is: toolchain collector → `/usr/bin/trash`
  → Finder → quarantine. Enforced by lint, not by convention.
- **No privilege escalation.** Root-owned paths get a printed command for you to
  run, never an automatic `sudo`.
- **No network access.** A tool that reads your whole disk should not be able to
  send anything. Also enforced by lint.
- **Dry-run by default.** Nothing changes without an explicit `--apply`.
- **Re-checked at the moment of action**, not only at scan time.

Never touched, at all: `/System`, `/usr`, `/bin`, `/sbin`, `/private/var/db`,
swap and the sleep image, Keychains, `~/.ssh`, `~/Library/Group Containers`
(live VM disks), Photos and Music library bundles, Mail storage, iOS device
backups, Xcode Archives, iCloud placeholders, and logs.

Full detail in [docs/SAFETY.md](docs/SAFETY.md), including an honest list of
what the test suite **cannot** cover, and [docs/PROJECTS.md](docs/PROJECTS.md)
for how the per-project scan decides what is safe.

## Requirements

- macOS 15 (Sequoia) or newer. `/usr/bin/trash` and `/usr/bin/jq` both arrived
  in 15, which is what lets this run with no dependencies at all.
- Nothing else. No Python, no Node, no Homebrew. Pure bash 3.2 and system tools.

Full Disk Access is **not** required. On macOS 26, `/usr/bin/trash` works
without it. Where a location genuinely cannot be read, that is reported rather
than silently skipped. Before granting FDA to a terminal, note that it is
inherited by every process that terminal launches.

## Development

```bash
tests/run.sh          # lint + all tests
tests/lint.sh         # invariants + shellcheck
```

The most important file is `tests/cases-guard.tsv`, a golden table asserting the
guard's verdict for every protected path. `tests/lint.sh` fails the build if a
deny rule is added without a corresponding test.

## Reading

The technical claims here are not original; they come from people who have
documented macOS internals carefully for years.

- Howard Oakley, [The Eclectic Light Company](https://eclecticlight.co/) -
  particularly [Please don't delete your logs](https://eclecticlight.co/2025/01/28/please-dont-delete-your-logs/),
  [Will flushing caches free up disk space?](https://eclecticlight.co/2023/09/22/will-flushing-caches-free-up-disk-space/),
  and [Can we make cleaning up our Macs simpler?](https://eclecticlight.co/2025/01/26/last-week-on-my-mac-can-we-make-cleaning-up-our-macs-simpler/)
- [Pearcleaner](https://github.com/alienator88/Pearcleaner) - the leftover
  matching approach in `/clean-apps` follows its design.
- [mac-cleanup-py](https://github.com/mac-cleanup/mac-cleanup-py) - a good
  survey of developer cache locations.
- [Objective-See](https://objective-see.org/) - KnockKnock and BlockBlock are
  the right tools for persistence and malware, which this is not.

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with MacPaw or CleanMyMac.
