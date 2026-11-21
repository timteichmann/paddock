#!/usr/bin/env bash
# Copyright (C) 2026 Tim Teichmann
# SPDX-License-Identifier: GPL-2.0-or-later
# Helpers are invoked indirectly through check/check_not:
# shellcheck disable=SC2317
#
# Arch package test, run as root in a fresh archlinux container by
# `tests/distro.sh arch-pkg` (checkout mounted read-only at $SRC). Copies the
# checkout (with .git) to a build user, runs `makepkg` in packaging/arch as
# the README says, lints with namcap, installs the package with its
# dependencies, checks it as a normal user, upgrades it after a new commit
# and removes it.

set -uo pipefail

SRC=${SRC:-/src}
U=pdinst B=pdbuild
BUILD=/home/$B/build
PASS=0 FAIL=0
declare -a FAILED=()

pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
as() { local u=$1; shift; runuser -u "$u" -- env -i HOME="/home/$u" USER="$u" PATH=/usr/bin:/bin bash -c "$*"; }
out_has() { grep -qE -- "$2" <<<"$1"; }

section "setup"
if [[ -f /ca.crt ]]; then
  cp /ca.crt /etc/ca-certificates/trust-source/anchors/extra.crt && trust extract-compat
fi
# The archlinux image skips extracting docs (NoExtract); extract everything
# so pacman -Qkk can check every file of the package.
sed -i '/^NoExtract/d' /etc/pacman.conf
check "base-devel, git and namcap" pacman -Syu --noconfirm --needed base-devel git namcap
check "create users $B and $U" bash -c "useradd -m $B && useradd -m $U"

REPO=/home/$B/paddock
cp -a "$SRC" "$REPO"
chown -R "$B:$B" "/home/$B"
BUILD=$REPO/packaging/arch
version=$("$SRC/paddock" version | awk '{print $2}')
built() { find "$BUILD" -maxdepth 1 -name 'paddock-*-any.pkg.tar.zst' -newer "$1" | head -n1; }
touch /tmp/t0

section "PKGBUILD"
out=$(namcap "$BUILD/PKGBUILD" 2>&1)
check_not "namcap PKGBUILD: no errors" out_has "$out" ' E: '
[[ -n $out ]] && printf '    %s\n' "$out"

section "build"
check "makepkg in packaging/arch" as "$B" "cd $BUILD && makepkg -f --nodeps"
pkgfile=$(built /tmp/t0)
check "package built" test -n "$pkgfile"
pkgfile=${pkgfile:-none}
rev=$(as "$B" "git -C $REPO rev-parse --short=7 HEAD")
check "version is $version.r<n>.g$rev" out_has "$(basename "$pkgfile")" "^paddock-${version//-/_}\\.r[0-9]+\\.g$rev-1-any"
out=$(namcap "$pkgfile" 2>&1)
check_not "namcap package: no errors" out_has "$out" ' E: '
[[ -n $out ]] && printf '    %s\n' "$out"
files=$(pacman -Qlp "$pkgfile" 2>/dev/null | awk '{print $2}')
check "contains /usr/bin/paddock" out_has "$files" '^/usr/bin/paddock$'
check "contains /usr/share/paddock/tools/claude/tool.conf" out_has "$files" '^/usr/share/paddock/tools/claude/tool.conf$'
check_not "nothing outside /usr" bash -c "grep -v '^/usr/' <<<'$files' | grep -q ."

section "install"
check "pacman -U pulls in the dependencies" pacman -U --noconfirm "$pkgfile"
for p in podman netavark curl; do check "dependency $p installed" pacman -Q "$p"; done
check "pacman -Qkk paddock: files intact" pacman -Qkk paddock
check "/usr/bin/paddock is executable" test -x /usr/bin/paddock
check "paddock version" test "$(as "$U" paddock version)" = "paddock $version"
check "paddock tools: claude from /usr/share/paddock" \
  out_has "$(as "$U" paddock tools)" '^claude .*/usr/share/paddock/tools/claude$'
out=$(as "$U" paddock doctor 2>&1)
check "doctor: data dir /usr/share/paddock" out_has "$out" 'ok +data dir /usr/share/paddock$'
check "doctor: podman version ok" out_has "$out" 'ok +podman [0-9]'
check "doctor: newuidmap/newgidmap ok" out_has "$out" 'ok +newuidmap/newgidmap'
check "doctor: /etc/subuid ok" out_has "$out" "ok +/etc/subuid has an entry for $U"

section "upgrade after a new commit"
as "$B" "cd $REPO && echo '# local change' >> share/domains.txt && git -c user.name=t -c user.email=t@t commit -qam test"
touch /tmp/t1
check "makepkg again" as "$B" "cd $BUILD && makepkg -f --nodeps"
pkg2=$(built /tmp/t1)
check "new package has a higher version" test "$(vercmp "$(pacman -Qp "${pkg2:-none}" 2>/dev/null | awk '{print $2}')" "$(pacman -Q paddock | awk '{print $2}')")" = 1
check "pacman -U upgrades" pacman -U --noconfirm "${pkg2:-none}"
check "upgrade installed the change" grep -qx '# local change' /usr/share/paddock/domains.txt

section "remove"
as "$U" 'mkdir -p ~/.config/paddock && echo pypi.org > ~/.config/paddock/domains.txt'
check "pacman -R paddock" pacman -R --noconfirm paddock
check_not "/usr/bin/paddock removed" test -e /usr/bin/paddock
check_not "/usr/share/paddock removed" test -e /usr/share/paddock
check "user config kept" test -f "/home/$U/.config/paddock/domains.txt"

printf '\narch-pkg: %d passed, %d failed\n' "$PASS" "$FAIL"
if ((FAIL)); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
