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
#
# Never touches ~/.config/paddock (your instances, overrides and config) or
# any Podman images, containers or volumes.

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DESTDIR=${DESTDIR-}
prefix="" uninstall=0

die() { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }
say() { printf 'install.sh: %s\n' "$*"; }

usage() { sed -n '5,13s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

while (($#)); do
  case $1 in
    --prefix) (($# >= 2)) || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --prefix=*) prefix=${1#*=}; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument '$1'" ;;
  esac
done

if [[ -z $prefix ]]; then
  if ((EUID == 0)); then prefix=/usr/local; else prefix=$HOME/.local; fi
fi
[[ $prefix == /* ]] || die "--prefix must be an absolute path"
prefix=${prefix%/}

bin=$DESTDIR$prefix/bin/paddock
data=$DESTDIR$prefix/share/paddock
doc=$DESTDIR$prefix/share/doc/paddock

# --------------------------------------------------------------- uninstall --
if ((uninstall)); then
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
  ((removed)) || say "nothing installed under $DESTDIR$prefix"
  say "kept your config and instances in \${XDG_CONFIG_HOME:-~/.config}/paddock"
  exit 0
fi

# ----------------------------------------------------------------- install --
[[ -f $SRC/paddock && -f $SRC/share/config && -d $SRC/share/tools ]] \
  || die "run install.sh from a paddock checkout ($SRC has no paddock or share/)"

install -d -m 0755 "$(dirname "$bin")" "$doc"
install -m 0755 "$SRC/paddock" "$bin"

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
