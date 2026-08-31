#!/bin/bash
# scan_projects.sh -- build and dependency directories inside individual projects.
#
# Distinct from lib/scan.sh's dev scan, which reclaims GLOBAL tool caches at
# fixed paths. This finds the artifacts that live inside whatever projects a
# person happens to have, wherever they keep them.
#
# The two guarantees this module exists to provide:
#
#   1. It does not touch a project that is under active development. A running
#      dev server, an uncommitted change, a stash, or a recent commit all veto.
#      Dependency directories are protected outright in an active project,
#      because restoring one costs a reinstall; build output is still offered,
#      because it regenerates from source alone.
#
#   2. It never deletes source. A directory tracked in git is source by
#      definition and is refused at any age, with any flag. Names like `build`,
#      `dist`, `out` and `vendor` are also used for hand-written code, so they
#      are never preselected and are confirmed one at a time.

CMAI_PROJ_W=""   # scratch directory for this scan's intermediate TSVs

# ---------------------------------------------------------------- discovery

# _cmai_proj_find <root> -- NUL-separated marker directories, ONE traversal.
#
# Ordering is load-bearing for BSD find. The exclusion group comes first with a
# bare -prune: never wanted, never walked into. The marker group comes second
# with -print0 -prune: emitted AND not descended. That is "prune on descend,
# match on name", and it is what stops a single node_modules from contributing
# hundreds of nested `dist` rows.
#
# Putting node_modules, vendor, Pods and .venv in the MARKER group is the
# optimisation, not a cost: matching them halts the walk at the top of the
# largest trees on the disk. Measured on a full home directory, a per-marker
# loop took 11.6s and returned 2586 paths; this returns 200 in under a second.
_cmai_proj_find() {
  local root="$1" name class tier amb man lock inm restore why p
  local ex mk

  # Exclusions. Each is here because it produced false positives in practice.
  # Dotted directories directly under $HOME are tool homes (~/.vscode, ~/.local,
  # ~/.npm), not projects. Anchored to $HOME rather than to $root: with
  # `--root ~/Development/foo` the latter would prune that project's own
  # .dart_tool and .next, which are exactly what we came for.
  ex=( -path "$HOME/.*" )
  ex=( "${ex[@]}" -o -path "$HOME/Library" )  # app state; also where ~/Library/Caches lives
  ex=( "${ex[@]}" -o -path "$HOME/Applications" -o -path "$HOME/.Trash" )
  ex=( "${ex[@]}" -o -path "$HOME/Library/Mobile Documents" )  # iCloud: traversal materializes
  # Bundles are opaque. An .app has a Contents/ full of build-looking names, and
  # a Photos library must never be walked at all.
  ex=( "${ex[@]}" -o -name '*.app' -o -name '*.appex' -o -name '*.framework' )
  ex=( "${ex[@]}" -o -name '*.photoslibrary' -o -name '*.photolibrary' )
  ex=( "${ex[@]}" -o -name '*.musiclibrary' -o -name '*.tvlibrary' -o -name '*.fcpbundle' )
  ex=( "${ex[@]}" -o -name '.git' )           # thousands of loose-object dirs, no artifacts
  ex=( "${ex[@]}" -o -name '__pycache__' )    # individually far below any size floor
  ex=( "${ex[@]}" -o -name '.pnpm' )          # hardlinks into the global store

  # Everything catalog-dev.tsv claims is a GLOBAL cache owned by /clean-dev.
  # Without this, ~/go/pkg/mod alone yields rows like
  # .../golang.org/x/text@v0.36.0/collate/build -- which is source, not output.
  # Note ~/go and ~/miniconda3 are not dotdirs, so the rule above misses them.
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    ex=( "${ex[@]}" -o -path "$p" )
  done <<EOF
$(_cmai_dev_paths)
EOF

  while IFS=$'\t' read -r name class tier amb man lock inm restore why; do
    case "$name" in \#*|'') continue ;; esac
    [ -n "${why:-}" ] || continue
    if [ -z "${mk:-}" ]; then mk=( -name "$name" ); else mk=( "${mk[@]}" -o -name "$name" ); fi
  done < "$CMAI_DATA_DIR/catalog-projects.tsv"
  [ -n "${mk:-}" ] || return 0

  $FIND "$root" -xdev \( "${ex[@]}" \) -prune -o \
        \( -type d \( "${mk[@]}" \) -print0 -prune \) 2>/dev/null
  return 0
}

# A project declares itself with a manifest or a repository. Without this the
# scan reports installed software as if it were the user's work: VS Code
# extensions, Neovim plugins and the npx cache all contain these directory
# names. Measured on a full home directory, this filter removed 891 of 1055.
_cmai_proj_is_project() {
  local d="$1" m
  [ -d "$d/.git" ] || [ -f "$d/.git" ] && return 0
  for m in package.json Cargo.toml pubspec.yaml pyproject.toml go.mod pom.xml \
           build.gradle build.gradle.kts settings.gradle Podfile composer.json \
           mix.exs CMakeLists.txt Package.swift requirements.txt setup.py \
           Gemfile stack.yaml cabal.project turbo.json nuxt.config.ts \
           svelte.config.js angular.json next.config.js next.config.ts; do
    [ -f "$d/$m" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- phase 0
# Collected once for the whole machine, not per project.

_cmai_proj_phase0() {
  local W="$1" db

  # Live process working directories: the definitive "in use" veto, and the one
  # signal no comparable tool uses. `lsof -d cwd` restricts the descriptor set
  # before enumerating, so this is one cheap call rather than a walk per project.
  # `lsof +D` would be the slow one and is never used here.
  $LSOF -w -n -P -d cwd -Fn 2>/dev/null \
  | $AWK -v home="$HOME" '
      /^n\// { p = substr($0, 2)
        if (p == "/" || p == home) next
        if (index(p, home "/Library/") == 1) next
        n = split(p, a, "/"); if (n - 1 < 3) next
        print p }' \
  | $SORT -u > "$W/cwd.txt" 2>/dev/null || : > "$W/cwd.txt"

  # JetBrains records a real epoch-millisecond timestamp for when a project was
  # last focused. That is the highest-quality "last worked on" signal available
  # on macOS: atime is not updated on read on APFS, and kMDItemLastUsedDate is
  # null for directories and source files, so both are useless here.
  : > "$W/ide.tsv"
  $FIND "$HOME/Library/Application Support/JetBrains" -maxdepth 3 \
        -name recentProjects.xml -print0 2>/dev/null \
  | $XARGS -0 -n 1 "$AWK" -v home="$HOME" '
      /<entry key="/ {
        line = $0; sub(/^.*<entry key="/, "", line); sub(/".*$/, "", line)
        gsub(/\$USER_HOME\$/, home, line)
        key = line; ts = 0; next
      }
      key != "" && /name="(activationTimestamp|projectOpenTimestamp)"/ {
        v = $0; sub(/^.*value="/, "", v); sub(/".*$/, "", v); v = v + 0
        if (v > ts) ts = v
      }
      key != "" && /<\/entry>/ {
        if (ts > 0) printf "%d\t%s\n", int(ts / 1000), key
        key = ""; ts = 0
      }' 2>/dev/null \
  | $SORT -t"$CMAI_TAB" -k2,2 -k1,1nr | $AWK -F'\t' '!seen[$2]++' > "$W/ide.tsv" 2>/dev/null || :

  # VS Code's recents list moved in 1.118 from globalStorage to a shared store.
  # Read the new location first, fall back to the old. immutable=1 so a running
  # editor's write-ahead log is neither blocked nor disturbed.
  #
  # This list is MRU RANK ONLY -- it carries no timestamps. Deriving a date from
  # a rank would be exactly the invented number this project exists to avoid, so
  # it contributes a boolean and nothing more.
  : > "$W/vscode.txt"
  for db in "$HOME/.vscode-shared/sharedStorage/state.vscdb" \
            "$HOME/Library/Application Support/Code/User/globalStorage/state.vscdb"; do
    [ -f "$db" ] || continue
    $SQLITE3 "file:$db?immutable=1" \
      "select value from ItemTable where key='history.recentlyOpenedPathsList';" 2>/dev/null \
    | $TR ',' '\n' \
    | $SED -n 's|.*"folderUri":"file://\([^"]*\)".*|\1|p' \
    | $AWK 'NR <= 10 { print }' >> "$W/vscode.txt" 2>/dev/null || :
  done
  $SORT -u "$W/vscode.txt" > "$W/vscode.sorted" 2>/dev/null || : > "$W/vscode.sorted"
  return 0
}

# ---------------------------------------------------------------- resolution

# The repository root, else the nearest ancestor holding a manifest, else the
# parent. Scoring happens once per root: a monorepo has many artifact
# directories and exactly one activity story.
_cmai_proj_root() {
  local art="$1" parent d top
  parent=$($DIRNAME "$art")
  top=$($GIT -C "$parent" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ]; then printf '%s\n' "$top"; return 0; fi
  d="$parent"
  while [ "$d" != "$HOME" ] && [ "$d" != "/" ]; do
    if _cmai_proj_is_project "$d"; then printf '%s\n' "$d"; return 0; fi
    d=$($DIRNAME "$d")
  done
  printf '%s\n' "$parent"
  return 0
}

# ---------------------------------------------------------------- scoring

# _cmai_proj_score <root> <hot> -- one TSV line for scores.tsv:
#   root last_touch src active keep dirty unpushed stashed vcs
_cmai_proj_score() {
  local r="$1" hot="$2" W="$CMAI_PROJ_W"
  local lt=0 t src=none keep=0 dirty=0 unpushed=0 stashed=0 vcs=none active=0 d now

  # .cmaikeep protects a project, and protects everything under a marked
  # ancestor so a whole client directory can be excluded at once.
  d="$r"
  while [ "$d" != "$HOME" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.cmaikeep" ]; then keep=1; break; fi
    d=$($DIRNAME "$d")
  done

  if [ -d "$r/.git" ] || [ -f "$r/.git" ]; then
    vcs=git
    t=$($GIT -C "$r" log -1 --format=%ct 2>/dev/null) || t=""
    if [ -n "$t" ] && [ "$t" -gt "$lt" ] 2>/dev/null; then lt=$t; src=commit; fi
    # A commit date misses checkouts, rebases and branch switches; the reflog
    # catches exactly those, and costs one stat.
    #
    # .git/index is deliberately NOT consulted. Measured on this machine, it
    # read 0 days old for repositories whose last commit was 53 and 195 days
    # ago, because any IDE or shell prompt running `git status` in the
    # background refreshes it. Including it made every project look active.
    t=$($STAT -f '%m' "$r/.git/logs/HEAD" 2>/dev/null) || t=""
    if [ -n "$t" ] && [ "$t" -gt "$lt" ] 2>/dev/null; then lt=$t; src=git-ref; fi
  fi

  # IDE focus time, matched on the exact project root.
  t=$($AWK -F'\t' -v k="$r" '$2 == k { print $1; exit }' "$W/ide.tsv" 2>/dev/null)
  if [ -n "$t" ] && [ "$t" -gt "$lt" ] 2>/dev/null; then lt=$t; src=jetbrains; fi

  # Manifest and lockfile mtimes: the cheapest proxy for "a dependency changed",
  # and the only signal at all for the projects that are not repositories.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    t=$($STAT -f '%m' "$d" 2>/dev/null) || continue
    if [ "$t" -gt "$lt" ] 2>/dev/null; then lt=$t; src=manifest; fi
  done <<EOF
$($FIND "$r" -maxdepth 1 \( -name 'package.json' -o -name '*.lock' -o -name '*lock.json' \
   -o -name '*lock.yaml' -o -name 'Cargo.toml' -o -name 'go.mod' -o -name 'pyproject.toml' \
   -o -name 'pubspec.yaml' -o -name 'Podfile' -o -name 'composer.json' -o -name 'mix.exs' \) 2>/dev/null)
EOF

  now=$($DATE +%s)
  if [ "$lt" -gt 0 ] 2>/dev/null; then
    [ "$(( (now - lt) / 86400 ))" -le "$CMAI_PROJ_ACTIVE_DAYS" ] && active=1
  fi

  # A live working directory anywhere under the root means the project is in use
  # right now, whatever the timestamps say.
  if [ -n "$($AWK -v p="$r" 'index($0, p "/") == 1 || $0 == p { print; exit }' "$W/cwd.txt" 2>/dev/null)" ]; then
    active=1
  fi
  # VS Code contributes membership only; there is no timestamp to read.
  if [ -n "$($GREP -xF "$r" "$W/vscode.sorted" 2>/dev/null)" ]; then active=1; fi

  # The expensive checks run only for roots that actually have a candidate over
  # the size floor. Unbacked-up work vetoes preselection for the whole repo.
  if [ "$hot" = 1 ] && [ "$vcs" = git ]; then
    # --no-optional-locks is a top-level git option; as a status flag it exits 129.
    # .cmaikeep is excluded from the dirty check, or adding one would mark the
    # repo dirty and suppress preselection everywhere -- self-reinforcing.
    if [ -n "$($GIT --no-optional-locks -C "$r" status --porcelain -uno 2>/dev/null \
               | $GREP -v '\.cmaikeep$')" ]; then dirty=1; fi
    # Exits 128 when the branch has no upstream, which is itself a signal that
    # the work is unbacked-up. @{u} is quoted so bash does not brace-expand it.
    t=$($GIT -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null) || t=""
    if [ -z "$t" ]; then
      [ -n "$($GIT -C "$r" log -1 --format=%H 2>/dev/null)" ] && unpushed=1
    elif [ "$t" -gt 0 ] 2>/dev/null; then unpushed=1; fi
    [ -n "$($GIT -C "$r" stash list 2>/dev/null)" ] && stashed=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$r" "$lt" "$src" "$active" "$keep" "$dirty" "$unpushed" "$stashed" "$vcs"
}

# Is the artifact tracked in git? Then it is source, and this is a hard stop.
# Composer and Go projects commit vendor/ deliberately, and libraries commit
# dist/. Without this check a plausible-looking rule deletes committed code.
_cmai_proj_tracked() {
  local root="$1" art="$2" rel
  [ -d "$root/.git" ] || [ -f "$root/.git" ] || return 1
  rel=${art#"$root"/}
  [ "$rel" = "$art" ] && return 1
  $GIT -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1
}

# ---------------------------------------------------------------- main

# Remove this scan's scratch directory. Deliberately not a recursive removal:
# production code in this project never recurses when deleting, and the lint
# gate that enforces that is dumb on purpose so it cannot be argued with. The
# scratch directory only ever holds flat TSV files, so this is sufficient.
_cmai_proj_cleanup() {
  local W="$1" f
  [ -n "$W" ] && [ -d "$W" ] || return 0
  case "$W" in */cmai-proj.*) ;; *) return 0 ;; esac
  for f in "$W"/*; do [ -e "$f" ] && /bin/rm "$f" 2>/dev/null; done
  /bin/rmdir "$W" 2>/dev/null
  return 0
}

cmai_scan_projects() {
  local root="${OPT_ROOT:-$HOME}" W minb
  local art parent name class tier amb man lock inm restore why
  local crow bytes proot hot
  local lt src active keep dirty unpushed stashed vcs
  local age artage haslock hasman inmok pnpm verdict_floor evidence tag sub note

  minb="${CMAI_PROJ_MIN}"
  [ -n "${OPT_MINSIZE:-}" ] && minb=$(cmai_to_bytes "$OPT_MINSIZE")

  W=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cmai-proj.XXXXXX") || return 0
  CMAI_PROJ_W="$W"
  _cmai_proj_phase0 "$W"

  # --- discovery and sizing, one traversal then one parallel du pass --------
  # -n 1 keeps each du output under PIPE_BUF so parallel writers cannot interleave.
  _cmai_proj_find "$root" \
  | $XARGS -0 -P "$CMAI_PROJ_PARALLEL" -n 1 "$DU" -skx 2>/dev/null \
  | $AWK -F'\t' '{ b = $1 * 1024; p = $2; sub(/^[0-9]+[ \t]+/, "", $0); print b "\t" $0 }' \
  > "$W/sized.tsv" 2>/dev/null || : > "$W/sized.tsv"

  # --- keep only real project artifacts over the floor ----------------------
  : > "$W/markers.tsv"
  while IFS=$'\t' read -r bytes art; do
    [ -n "${art:-}" ] || continue
    [ "${bytes:-0}" -ge "$minb" ] 2>/dev/null || continue
    parent=$($DIRNAME "$art")
    _cmai_proj_is_project "$parent" || continue
    proot=$(_cmai_proj_root "$art")
    printf '%s\t%s\t%s\n' "$proot" "$art" "$bytes" >> "$W/markers.tsv"
  done < "$W/sized.tsv"
  [ -s "$W/markers.tsv" ] || { _cmai_proj_cleanup "$W"; return 0; }

  # --- score each root once -------------------------------------------------
  $AWK -F'\t' '!seen[$1]++ { print $1 }' "$W/markers.tsv" > "$W/roots.tsv"
  : > "$W/scores.tsv"
  while IFS= read -r proot; do
    [ -n "$proot" ] || continue
    _cmai_proj_score "$proot" 1 >> "$W/scores.tsv"
  done < "$W/roots.tsv"

  # --- join and emit --------------------------------------------------------
  while IFS=$'\t' read -r proot art bytes; do
    [ -n "${art:-}" ] || continue
    name=$($BASENAME "$art")

    # Catalog row for this marker. A name may appear twice (Cargo and Maven
    # both use `target`); the row whose manifest is actually present wins.
    crow=$(_cmai_proj_catalog_row "$name" "$proot")
    [ -n "$crow" ] || continue
    class=$(printf  '%s' "$crow" | $AWK -F'\t' '{print $2}')
    tier=$(printf   '%s' "$crow" | $AWK -F'\t' '{print $3}')
    amb=$(printf    '%s' "$crow" | $AWK -F'\t' '{print $4}')
    man=$(printf    '%s' "$crow" | $AWK -F'\t' '{print $5}')
    lock=$(printf   '%s' "$crow" | $AWK -F'\t' '{print $6}')
    inm=$(printf    '%s' "$crow" | $AWK -F'\t' '{print $7}')
    restore=$(printf '%s' "$crow" | $AWK -F'\t' '{print $8}')
    why=$(printf    '%s' "$crow" | $AWK -F'\t' '{print $9}')

    IFS=$'\t' read -r _r lt src active keep dirty unpushed stashed vcs <<EOF
$($GREP -m1 "^$(cmai_tsv_safe "$proot")$CMAI_TAB" "$W/scores.tsv" 2>/dev/null)
EOF

    sub="project-${class}"
    note=""

    # --- V2: an explicit keep marker wins over everything below -------------
    if [ "${keep:-0}" = 1 ]; then
      cmai_emit dev "$sub" "$art" review report irreversible "$($BASENAME "$proot")" \
        "$why Protected by a .cmaikeep marker in this project or an ancestor of it." info "$bytes"
      continue
    fi

    # --- V3: tracked in git means it is source. No flag overrides this. -----
    if _cmai_proj_tracked "$proot" "$art"; then
      cmai_emit dev "$sub" "$art" risky report irreversible "$($BASENAME "$proot")" \
        "This directory is tracked in git, so it is source rather than build output. Refused at any age." info "$bytes"
      continue
    fi

    # --- V4: a live process is working inside it ----------------------------
    if [ -n "$($AWK -v p="$art" 'index($0, p "/") == 1 || $0 == p { print; exit }' "$W/cwd.txt" 2>/dev/null)" ]; then
      cmai_emit dev "$sub" "$art" risky report irreversible "$($BASENAME "$proot")" \
        "A running process has its working directory inside this path. Removing it now would break that process." info "$bytes"
      continue
    fi

    # --- V5: written to within the last day; a build is probably running ----
    #
    # Modification time, not birth time. "A build is in progress" means
    # something is writing here now; a directory created 23 hours ago and
    # untouched since is not being built. Birth time is also unsettable, which
    # would make this branch untestable.
    artage=$(cmai_mtime_days "$art")
    if [ "${artage:-999}" -lt 1 ] 2>/dev/null; then
      cmai_emit dev "$sub" "$art" review report full "$($BASENAME "$proot")" \
        "$why Created within the last 24 hours, so a build is probably in progress." info "$bytes"
      continue
    fi

    # --- V6: dependency directory in an active project ----------------------
    if [ "$class" = deps ] && [ "${active:-0}" = 1 ] && [ "${OPT_INCLUDE_ACTIVE:-0}" != 1 ]; then
      cmai_emit dev "$sub" "$art" review report full "$($BASENAME "$proot")" \
        "$why This project is in active use and restoring this would cost a reinstall, so it is protected. Use --include-active to consider it anyway." info "$bytes"
      continue
    fi

    # --- tier adjustment and the preselect decision --------------------------
    age=-1
    if [ "${lt:-0}" -gt 0 ] 2>/dev/null; then age=$(( ( $($DATE +%s) - lt ) / 86400 )); fi

    haslock=none
    if [ "$lock" != "-" ]; then
      haslock=$(_cmai_proj_have_any "$proot" "$lock")
    fi
    # A lockfile-backed row without its lockfile is only manifest-backed: the
    # versions that come back may differ from the ones that were there.
    [ "$tier" = T1 ] && [ "$haslock" = none ] && tier=T2

    inmok=na
    if [ "$inm" != "-" ]; then
      if [ -e "$art/$inm" ]; then inmok=ok; else inmok=missing; fi
    fi

    pnpm=no
    [ -d "$art/.pnpm" ] && pnpm=yes

    verdict_floor=""
    if [ "$amb" = 1 ]; then verdict_floor=ask; fi                                  # O1
    if [ "$class" != deps ] && [ "${active:-0}" = 1 ]; then verdict_floor=ask; fi   # O2
    # In-flight work suppresses preselection. Note what is NOT here: unpushed
    # commits. They live in .git and are not endangered by removing regenerable
    # build output, and treating "no upstream" as a veto would permanently
    # disqualify every local-only repository. It is still reported as context.
    if [ "${dirty:-0}" = 1 ] || [ "${stashed:-0}" = 1 ]; then verdict_floor=ask; fi
    if [ "$inmok" = missing ]; then verdict_floor=ask; fi                          # O6
    # O7: no repository AND no manifest means nothing here can be regenerated
    # from a declared source, so it is never preselected. A project without git
    # but WITH a manifest is perfectly ordinary and stays eligible.
    hasman=none
    [ "$man" != "-" ] && hasman=$(_cmai_proj_have_any "$proot" "$man")
    if [ "$vcs" = none ] && [ "$hasman" = none ]; then verdict_floor=ask; fi
    if [ "${artage:-999}" -lt "$CMAI_PROJ_FRESH_DAYS" ] 2>/dev/null; then verdict_floor=ask; fi
    if [ "$pnpm" = yes ]; then verdict_floor=ask; fi                               # O9

    # O3: idle long enough for its tier?
    case "$tier" in
      T3) [ "$age" -ge "$CMAI_PROJ_T3_DAYS" ] 2>/dev/null || verdict_floor=ask ;;
      T1) [ "$age" -ge "$CMAI_PROJ_T1_DAYS" ] 2>/dev/null || verdict_floor=ask ;;
      *)  [ "$age" -ge "$CMAI_PROJ_T2_DAYS" ] 2>/dev/null || verdict_floor=ask ;;
    esac
    [ -n "${OPT_DAYS_SET:-}" ] && { [ "$age" -ge "$OPT_DAYS" ] 2>/dev/null || verdict_floor=ask; }

    # --- evidence -----------------------------------------------------------
    if [ "$age" -ge 0 ] 2>/dev/null; then
      note="Last worked on ${age} days ago (${src})."
    else
      note="No activity signal available for this project."
    fi
    [ "${dirty:-0}" = 1 ]    && note="$note Working tree has uncommitted changes."
    [ "${unpushed:-0}" = 1 ] && note="$note Commits are not pushed to any upstream."
    [ "${stashed:-0}" = 1 ]  && note="$note The repository has stashes."
    [ "$inmok" = missing ]   && note="$note Expected marker $inm is absent, so this may not be build output at all."
    [ "$amb" = 1 ]           && note="$note The name is also used for source directories, so this is never selected for you."
    [ "$vcs" = none ]        && note="$note This project is not a git repository, so there is no commit history to judge it by."
    [ "$pnpm" = yes ]        && note="$note This is a pnpm store layout: most of its bytes are hardlinks into the global store, so removing it frees less than the size shown. Run \`pnpm store prune\` for the rest."
    [ "$haslock" != none ] && [ "$haslock" != "-" ] && note="$note Lockfile $haslock is present."

    tag="[cmai class=$class tier=$tier age=$age active=${active:-0} lock=$haslock inmarker=$inmok restore=\"$restore\"]"
    evidence="$why $note Restore with: $restore $tag"

    cmai_emit dev "$sub" "$art" safe trash rebuildable "$($BASENAME "$proot")" \
      "$evidence" "$verdict_floor" "$bytes"
  done < "$W/markers.tsv"

  _cmai_proj_cleanup "$W"
  CMAI_PROJ_W=""
  return 0
}

# The catalog row for a marker name. When a name appears more than once (Cargo
# and Maven both use `target`), the row whose manifest is actually present at
# the project root wins; otherwise the first row is used.
_cmai_proj_catalog_row() {
  local want="$1" proot="$2" name class tier amb man lock inm restore why first=""
  while IFS=$'\t' read -r name class tier amb man lock inm restore why; do
    case "$name" in \#*|'') continue ;; esac
    [ -n "${why:-}" ] || continue
    [ "$name" = "$want" ] || continue
    [ -z "$first" ] && first="$name	$class	$tier	$amb	$man	$lock	$inm	$restore	$why"
    if [ "$man" != "-" ] && [ "$(_cmai_proj_have_any "$proot" "$man")" != none ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$class" "$tier" "$amb" "$man" "$lock" "$inm" "$restore" "$why"
      return 0
    fi
  done < "$CMAI_DATA_DIR/catalog-projects.tsv"
  [ -n "$first" ] && printf '%s\n' "$first"
  return 0
}

# The first of a comma-separated list of filenames that exists at a root, or
# "none". Used for both manifests and lockfiles.
_cmai_proj_have_any() {
  local root="$1" list="$2" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$root/$f" ] && { printf '%s\n' "$f"; return 0; }
  done <<EOF
$(printf '%s' "$list" | $TR ',' '\n')
EOF
  printf 'none\n'
  return 0
}
