#!/usr/bin/env bash
# Copyright (C) 2026 Tim Teichmann
# SPDX-License-Identifier: GPL-2.0-or-later
# Helpers are invoked indirectly through check/check_not:
# shellcheck disable=SC2317
#
# Install test, run as root inside a fresh distro container by tests/distro.sh
# (the checkout is mounted read-only at $SRC, default /src). Installs the host
# packages with the distro's package manager, then checks install.sh (user,
# system, custom prefix, DESTDIR, reinstall, uninstall) and `paddock doctor`
# as a normal user. Running containers needs nested rootless Podman, so
# tests/acceptance.sh is not run here.

set -uo pipefail

SRC=${SRC:-/src}
U=pdinst
PASS=0 FAIL=0
declare -a FAILED=()

pass() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }
# Run a command as the test user with a login-like environment.
as_user() { runuser -u "$U" -- env -i HOME="/home/$U" USER="$U" PATH="/home/$U/.local/bin:/usr/local/bin:/usr/bin:/bin" bash -c "$1"; }
out_has() { grep -qE -- "$2" <<<"$1"; }

# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release
ID=${ID:-unknown}
printf 'install test on %s\n' "${PRETTY_NAME:-$ID}"

# Optional extra CA (e.g. a TLS-intercepting proxy) mounted at /ca.crt.
add_ca() {
  [[ -f /ca.crt ]] || return 0
  if [[ -d /etc/ca-certificates/trust-source/anchors ]]; then
    cp /ca.crt /etc/ca-certificates/trust-source/anchors/extra.crt && trust extract-compat
  elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
    cp /ca.crt /etc/pki/ca-trust/source/anchors/extra.crt && update-ca-trust
  elif [[ -d /etc/apt ]]; then
    # Such proxies usually allow only CONNECT: switch apt to HTTPS mirrors
    # and trust the CA before ca-certificates is installed.
    printf 'Acquire::https::CAInfo "/ca.crt";\n' >/etc/apt/apt.conf.d/99extra-ca
    sed -i 's|http://|https://|g' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null
    return 0
  fi
}

pkg_install() { # base | full
  case $ID in
    arch)
      [[ $1 == base ]] && return 0
      pacman -Syu --noconfirm --needed podman curl >/dev/null ;;
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      if [[ $1 == base ]]; then
        apt-get update -qq && apt-get install -y -qq ca-certificates >/dev/null
      else
        apt-get install -y -qq podman uidmap slirp4netns curl >/dev/null
      fi ;;
    fedora)
      [[ $1 == base ]] && { dnf install -y -q util-linux shadow-utils findutils >/dev/null; return; }
      dnf install -y -q podman curl >/dev/null ;;
    *) echo "unsupported distro '$ID'" >&2; return 1 ;;
  esac
}

section "setup"
add_ca
check "base packages ($ID)" pkg_install base
check "create user $U" useradd -m -s /bin/bash "$U"

section "doctor without podman"
out=$(as_user "$SRC/paddock doctor" 2>&1); rc=$?
check "doctor fails" test "$rc" -ne 0
check "doctor reports podman missing" out_has "$out" 'FAIL +podman not found'
check "doctor points to the Podman install docs" out_has "$out" 'podman\.io/docs/installation'
check "doctor finds the checkout's data dir" out_has "$out" "ok +data dir $SRC/share"

section "host packages"
check "install podman ($ID)" pkg_install full
check "podman installed" command -v podman

section "user install (~/.local)"
out=$(as_user "cd /tmp && $SRC/install.sh" 2>&1)
check "install.sh as user" test -x "/home/$U/.local/bin/paddock"
check "data dir installed" test -f "/home/$U/.local/share/paddock/tools/claude/tool.conf"
check "doc installed" test -f "/home/$U/.local/share/doc/paddock/README.md"
check "bash completion installed" test -f "/home/$U/.local/share/bash-completion/completions/paddock"
check "files owned by the user" test "$(stat -c %U "/home/$U/.local/share/paddock/config")" = "$U"
check "install.sh runs paddock doctor" out_has "$out" 'checking the host'
check "paddock on PATH" test "$(as_user 'command -v paddock')" = "/home/$U/.local/bin/paddock"
check "paddock version" out_has "$(as_user 'paddock version')" '^paddock [0-9]'
check "paddock tools: claude from ~/.local/share" \
  out_has "$(as_user 'paddock tools')" "^claude .*/home/$U/.local/share/paddock/tools/claude$"
check "paddock help shows the installed data dir" \
  out_has "$(as_user 'paddock help')" "^Data: +/home/$U/.local/share/paddock$"
# Completion without bash-completion itself (its fallback path).
complete_as_user() { # words... -> COMPREPLY
  as_user "source ~/.local/share/bash-completion/completions/paddock
    COMP_WORDS=($*); COMP_CWORD=\$((\${#COMP_WORDS[@]} - 1)); _paddock; echo \"\${COMPREPLY[*]}\""
}
check "completion: paddock cr -> create" test "$(complete_as_user paddock cr)" = create
check "completion: paddock build '' -> claude codex-local llm" \
  test "$(complete_as_user paddock build "''")" = "claude codex-local llm"
check "completion: paddock llm st -> start status stop" test "$(complete_as_user paddock llm st)" = "start stop status"
check "completion: paddock purge --k -> --keep-images" \
  test "$(complete_as_user paddock purge --k)" = --keep-images
check_not "completion does not create the config dir" test -e "/home/$U/.config/paddock"
out=$(as_user 'paddock doctor' 2>&1)
check "doctor: podman version ok" out_has "$out" 'ok +podman [0-9]'
check "doctor: newuidmap/newgidmap ok" out_has "$out" 'ok +newuidmap/newgidmap'

# Some distros (e.g. Arch) do not give new users subordinate IDs; doctor's
# fix must then work as printed.
if out_has "$out" 'FAIL +/etc/subuid'; then
  fix=$(grep -m1 -oE 'sudo usermod .*' <<<"$out")
  check "applying doctor's subuid fix" bash -c "${fix#sudo }"
  out=$(as_user 'paddock doctor' 2>&1)
fi
check "doctor: /etc/subuid ok" out_has "$out" "ok +/etc/subuid has an entry for $U"
check "doctor: /etc/subgid ok" out_has "$out" "ok +/etc/subgid has an entry for $U"

section "reinstall"
as_user 'mkdir -p ~/.config/paddock && echo pypi.org > ~/.config/paddock/domains.txt && touch ~/.local/share/paddock/stale'
check "reinstall" as_user "$SRC/install.sh"
check_not "stale data file removed" test -e "/home/$U/.local/share/paddock/stale"
check "user override kept" grep -qx pypi.org "/home/$U/.config/paddock/domains.txt"

section "user uninstall"
check "install.sh --uninstall" as_user "$SRC/install.sh --uninstall"
check_not "script removed" test -e "/home/$U/.local/bin/paddock"
check_not "data dir removed" test -e "/home/$U/.local/share/paddock"
check_not "bash completion removed" test -e "/home/$U/.local/share/bash-completion/completions/paddock"
check "config dir kept" test -f "/home/$U/.config/paddock/domains.txt"

section "uninstall --purge"
check_not "--purge without --uninstall refused" as_user "$SRC/install.sh --purge"
check_not "--uninstall --purge refused as root" "$SRC/install.sh" --uninstall --purge --force
check "reinstall" as_user "$SRC/install.sh"
check "install.sh --uninstall --purge --force" as_user "$SRC/install.sh --uninstall --purge --force"
check_not "config dir removed" test -e "/home/$U/.config/paddock"
check_not "script removed" test -e "/home/$U/.local/bin/paddock"
check "paddock purge: nothing left to purge" \
  out_has "$(as_user "$SRC/paddock purge --force" 2>&1)" 'nothing to purge'

section "system install (/usr/local, as root)"
check "install.sh as root" "$SRC/install.sh"
check "script in /usr/local/bin" test -x /usr/local/bin/paddock
check "files owned by root, world-readable" test "$(stat -c %U:%a /usr/local/share/paddock/config)" = root:644
check "paddock tools: claude from /usr/local/share" \
  out_has "$(as_user 'paddock tools')" '^claude .*/usr/local/share/paddock/tools/claude$'
out=$(paddock doctor 2>&1)
check "doctor refuses root" out_has "$out" 'FAIL +running as root'
check "install.sh --uninstall as root" "$SRC/install.sh" --uninstall
check_not "/usr/local/bin/paddock removed" test -e /usr/local/bin/paddock
check_not "/usr/local/share/paddock removed" test -e /usr/local/share/paddock

section "custom prefix (/opt/paddock)"
check "install.sh --prefix /opt/paddock" "$SRC/install.sh" --prefix /opt/paddock
check "paddock finds <prefix>/share/paddock" \
  out_has "$(as_user '/opt/paddock/bin/paddock tools')" '^claude .*/opt/paddock/share/paddock/tools/claude$'
ln -s /opt/paddock/bin/paddock /usr/local/bin/paddock
check "... also through a symlink" \
  out_has "$(as_user 'paddock tools')" '^claude .*/opt/paddock/share/paddock/tools/claude$'
rm -f /usr/local/bin/paddock
check "uninstall --prefix /opt/paddock" "$SRC/install.sh" --uninstall --prefix /opt/paddock
check_not "nothing left in /opt/paddock" bash -c 'find /opt/paddock -type f | grep -q .'

section "staged install (DESTDIR, for packages)"
check "DESTDIR=/tmp/stage install.sh --prefix /usr" env DESTDIR=/tmp/stage "$SRC/install.sh" --prefix /usr
check "staged script" test -x /tmp/stage/usr/bin/paddock
check "staged data dir" test -f /tmp/stage/usr/share/paddock/config
check "staged bash completion" test -f /tmp/stage/usr/share/bash-completion/completions/paddock
check_not "nothing written outside DESTDIR" test -e /usr/bin/paddock -o -e /usr/share/paddock
cp -a /tmp/stage/usr/. /usr/
check "packaged layout: paddock tools uses /usr/share/paddock" \
  out_has "$(as_user 'paddock tools')" '^claude .*/usr/share/paddock/tools/claude$'

section "safety"
mkdir -p /tmp/notpd/bin && echo '#!/bin/sh' >/tmp/notpd/bin/paddock
check_not "uninstall refuses a foreign bin/paddock" "$SRC/install.sh" --uninstall --prefix /tmp/notpd
check "foreign file kept" test -f /tmp/notpd/bin/paddock
check_not "install refuses a relative prefix" "$SRC/install.sh" --prefix relative/dir

printf '\n%s: %d passed, %d failed\n' "$ID" "$PASS" "$FAIL"
if ((FAIL)); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
