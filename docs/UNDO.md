# What can and cannot be undone

Every run writes an append-only manifest to
`~/.clean-mac-ai/manifest/<runid>.tsv`, and each entry is classed by whether it
can be reversed.

```bash
cmai runs                          # list runs
cmai show --run <runid>            # grouped by undo class
cmai restore --run <runid>         # preview
cmai restore --run <runid> --apply # restore
```

## The classes

| Class | Meaning |
|---|---|
| `full` | Moved, not deleted. Comes back intact. |
| `rebuildable` | Gone, but regenerated automatically by the tool that made it. |
| `irreversible` | Gone. Possibly re-downloadable, never restorable. |

## In detail

| Action | Undoable | Reality |
|---|---|---|
| Moved to Trash | **Yes, by you** | Finder → Put Back. `cmai` cannot do it without Full Disk Access, and cannot at all once the Trash is emptied. |
| Quarantined | **Yes, by cmai** | Restored with permissions intact, until `CMAI_ROOT` is cleared. |
| `brew cleanup` | No | Deletes downloaded bottles. Re-downloadable, costs bandwidth. |
| `brew autoremove` | No | Uninstalls formulae. The installed list is snapshotted into the manifest first, so it is at least reconstructable. |
| `docker builder prune` | No | Build cache gone. The next build is cold. |
| `docker image prune` | No | Re-pullable if the tag still exists upstream. Untagged local builds are gone permanently. |
| `go clean -modcache` | No | Re-downloadable via `go mod download`, given network and a live proxy. |
| `go clean -cache` | No | Rebuilt from source. Costs CPU only. |
| `npm cache clean` | No | Re-downloadable. |
| `pnpm store prune` | No | Re-downloadable; existing `node_modules` symlink farms may need reinstalling. |
| `xcrun simctl delete unavailable` | No | Only removes runtimes macOS already marked unusable. |
| Xcode DerivedData | No, but | Rebuildable at the cost of one clean build. |
| Launch agent removal | **Yes** | The plist is moved, and its label recorded so it can be re-bootstrapped. |
| Local snapshot thinning | N/A | `cmai` never runs it. It prints the command for you. |

## Why collectors cannot be undone

Running a toolchain's own garbage collector is preferred over deleting files:
higher yield, self-documenting, and its maintainers decide what is safe to drop.
The trade-off is that it hands control to that tool, and none of them offer an
undo.

This is stated before the run, not after. `cmai show` groups a run by undo class
so the irreversible portion is visible separately.

## Restore is conservative

Restore replays newest-first, so a child moved after its parent returns first.
It **never overwrites**: if something already exists at the original path it
reports a conflict and leaves both alone. Running restore twice is safe; the
second run reports conflicts rather than doing anything.

## Clearing the quarantine

Quarantined items live under `~/.clean-mac-ai/quarantine/` and occupy real disk
space until removed. They are kept deliberately - the space is not returned
until you are sure - and can be cleared with the Finder once you are.
