#!/bin/bash
# gc.sh -- run each toolchain's own garbage collector.
#
# Always preferred over deleting files. The tool's maintainers decide what is
# safe to drop, it understands its own on-disk layout, and it cannot be misled
# by a symlink the way a path walker can. Homebrew's cache is the cautionary
# tale: emptying it is fine, removing the directory broke installs
# (Homebrew/brew#5083).
#
# All of these are irreversible. The manifest says so rather than implying an
# undo that does not exist.

_cmai_have() { command -v "$1" >/dev/null 2>&1; }

cmai_gc_brew() {
  _cmai_have brew || return 0
  # Never with elevated privileges: Homebrew refuses, and rightly.
  cmai_reclaim_gc brew "homebrew cache" brew cleanup --prune=all -s
}

cmai_gc_docker() {
  _cmai_have docker || return 0
  cmai_reclaim_gc docker-builder "docker build cache" docker builder prune -af
  cmai_reclaim_gc docker-image   "dangling docker images" docker image prune -f
}

cmai_gc_npm()   { _cmai_have npm   || return 0; cmai_reclaim_gc npm   "npm cache"    npm cache clean --force; }
cmai_gc_pnpm()  { _cmai_have pnpm  || return 0; cmai_reclaim_gc pnpm  "pnpm store"   pnpm store prune; }
cmai_gc_yarn()  { _cmai_have yarn  || return 0; cmai_reclaim_gc yarn  "yarn cache"   yarn cache clean; }
cmai_gc_go()    {
  _cmai_have go || return 0
  cmai_reclaim_gc go-build "go build cache"  go clean -cache
  cmai_reclaim_gc go-mod   "go module cache" go clean -modcache
}
cmai_gc_pip()   { _cmai_have pip3  || return 0; cmai_reclaim_gc pip   "pip cache"    pip3 cache purge; }
cmai_gc_uv()    { _cmai_have uv    || return 0; cmai_reclaim_gc uv    "uv cache"     uv cache prune; }
cmai_gc_simctl() {
  _cmai_have xcrun || return 0
  # Only the unavailable ones: deleting live simulators would destroy their state.
  cmai_reclaim_gc simctl "unavailable simulators" xcrun simctl delete unavailable
}

_cmai_gc_run() {
  case "$1" in
    brew)   cmai_gc_brew ;;
    docker) cmai_gc_docker ;;
    npm)    cmai_gc_npm ;;
    pnpm)   cmai_gc_pnpm ;;
    yarn)   cmai_gc_yarn ;;
    go)     cmai_gc_go ;;
    pip)    cmai_gc_pip ;;
    uv)     cmai_gc_uv ;;
    simctl) cmai_gc_simctl ;;
    all)    cmai_gc_brew; cmai_gc_docker; cmai_gc_npm; cmai_gc_pnpm
            cmai_gc_yarn; cmai_gc_go; cmai_gc_pip; cmai_gc_uv; cmai_gc_simctl ;;
    *)      cmai_die "unknown gc target: $1 -- expected brew, docker, npm, pnpm, yarn, go, pip, uv, simctl or all" ;;
  esac
}

cmai_gc_dispatch() {
  printf 'status\ttool\tlabel\tbytes_or_cmd\n'
  _cmai_gc_run "$1"
}
