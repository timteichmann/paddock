#!/usr/bin/env bash
# Copyright (C) 2026 Tim Teichmann
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install or uninstall paddock (the script plus its data directory).
#
#   ./install.sh                     as a user: ~/.local, as root: /usr/local
#   ./install.sh --prefix /usr       any prefix (<prefix>/bin, <prefix>/share/paddock)
#   DESTDIR=pkg ./install.sh --prefix /usr     staged install for packagers
#   ./install.sh --uninstall [--prefix DIR]
#   ./install.sh --uninstall --purge [--force]   also `paddock purge` first
#
# Without --purge, never touches ~/.config/paddock (your instances, overrides
# and config) or any Podman images, containers or volumes.

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DESTDIR=${DESTDIR-}
prefix="" uninstall=0 purge=0 force=0

die() { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }
say() { printf 'install.sh: %s\n' "$*"; }

usage() { sed -n '5,14s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

while (($#)); do
  case $1 in
    --prefix) (($# >= 2)) || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --prefix=*) prefix=${1#*=}; shift ;;
    --uninstall) uninstall=1; shift ;;
    --purge) purge=1; shift ;;
    -f|--force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument '$1'" ;;
  esac
done

if [[ -z $prefix ]]; then
  if ((EUID == 0)); then prefix=/usr/local; else prefix=$HOME/.local; fi
fi
[[ $prefix == /* ]] || die "--prefix must be an absolute path"
prefix=${prefix%/}
((purge && !uninstall)) && die "--purge only goes with --uninstall"
((force && !purge)) && die "--force only goes with --purge"

bin=$DESTDIR$prefix/bin/paddock
data=$DESTDIR$prefix/share/paddock
doc=$DESTDIR$prefix/share/doc/paddock
# bash-completion loads <prefix>/share/bash-completion/completions/<cmd> on
# demand, including ~/.local/share (XDG_DATA_HOME) for user installs.
comp=$DESTDIR$prefix/share/bash-completion/completions/paddock

# --------------------------------------------------------------- uninstall --
if ((uninstall)); then
  if ((purge)); then
    # paddock state is per user (rootless Podman, ~/.config), so purge as root
    # would only clean up root's.
    ((EUID != 0)) || die "--purge removes your user's instances, images and config; run it as that user, not root"
    [[ -z $DESTDIR ]] || die "--purge does not go with DESTDIR"
    p=$bin; [[ -x $p ]] || p=$SRC/paddock
    args=(); ((force)) && args=(--force)
    "$p" purge "${args[@]}" || die "paddock purge failed; nothing uninstalled"
  fi
  removed=0
  if [[ -f $bin ]]; then
    grep -q '^# paddock - isolated coding-agent instances' "$bin" \
      || die "$bin is not paddock; not removing it"
    rm -f "$bin"; say "removed $bin"; removed=1
  fi
  if [[ -d $data ]]; then
    [[ -f $data/config && -d $data/tools ]] || die "$data does not look like a paddock data dir; not removing it"
    rm -rf "$data"; say "removed $data"; removed=1
  fi
  if [[ -d $doc ]]; then rm -rf "$doc"; say "removed $doc"; removed=1; fi
  if [[ -f $comp ]]; then
    grep -q '^# bash completion for paddock' "$comp" \
      || die "$comp is not paddock's completion; not removing it"
    rm -f "$comp"; say "removed $comp"; removed=1
  fi
  ((removed)) || say "nothing installed under $DESTDIR$prefix"
  ((purge)) || say "kept your config and instances in \${XDG_CONFIG_HOME:-~/.config}/paddock (remove them with 'paddock purge')"
  exit 0
fi

# ----------------------------------------------------------------- install --
[[ -f $SRC/paddock && -f $SRC/share/config && -d $SRC/share/tools ]] \
  || die "run install.sh from a paddock checkout ($SRC has no paddock or share/)"

install -d -m 0755 "$(dirname "$bin")" "$doc" "$(dirname "$comp")"
install -m 0755 "$SRC/paddock" "$bin"
install -m 0644 "$SRC/completions/paddock.bash" "$comp"

# Replace the data dir wholesale so files dropped upstream do not linger.
# User overrides live in the config dir and are unaffected.
if [[ -d $data ]]; then
  [[ -f $data/config && -d $data/tools ]] || die "$data exists but is not a paddock data dir"
  rm -rf "$data"
fi
(
  cd "$SRC/share"
  find . -type d -print0 | while IFS= read -r -d '' d; do install -d -m 0755 "$data/$d"; done
  find . -type f -print0 | while IFS= read -r -d '' f; do install -m 0644 "$f" "$data/$f"; done
)
install -m 0644 "$SRC/README.md" "$SRC/LICENSE" "$doc/"

say "installed $bin"
say "installed $data"
say "installed $comp"

[[ -n $DESTDIR ]] && exit 0

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) say "note: $prefix/bin is not in your PATH; add it, e.g. in ~/.profile:"
     # shellcheck disable=SC2016
     printf '    export PATH="%s/bin:$PATH"\n' "$prefix" ;;
esac

if ((EUID == 0)); then
  say "next: as your normal user, run 'paddock doctor' to check the host"
else
  say "checking the host (paddock doctor):"
  "$bin" doctor || say "fix the problems above, then run 'paddock doctor' again"
fi
