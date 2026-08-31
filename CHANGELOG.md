# Changelog

## 0.1.0

First release.

- Safety kernel with default-deny, SIP and immutability checks on both a path
  and its parent, symlink re-verification, iCloud placeholder refusal, and
  verdicts carried in exit codes so a caller cannot ignore them.
- Rule table with explicit deny/allow precedence: a permissive rule wins only
  when strictly more specific, and basename rules can never override a deny.
- Honest measurement: allocated blocks rather than logical size, hardlink
  deduplication by inode, candidate de-nesting, and `df`-verified reclaim
  figures with a noise floor.
- Trash-first removal via `/usr/bin/trash`, with Finder and quarantine
  fallbacks. No `rm` anywhere in the production code.
- Append-only manifest with undo classes, and a conservative restore that never
  overwrites.
- Toolchain collectors for Homebrew, Docker, npm, pnpm, yarn, Go, pip, uv and
  simctl, each measured individually.
- Six skills: clean-mac, clean-space, clean-dev, clean-apps, clean-guard,
  clean-tune.
- `cmai myths`, documenting what the tool refuses to do and why, with sources.
