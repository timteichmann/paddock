#!/usr/bin/env bash
# Copyright (C) 2026 Tim Teichmann
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Runs tests/install-test.sh in a fresh container per distro.
#
#   tests/distro.sh                 ubuntu and arch
#   tests/distro.sh ubuntu debian arch fedora
#   tests/distro.sh arch-pkg        build, install and remove the Arch package
#
# Distros: ubuntu (24.04), debian (13), arch, fedora; arch-pkg runs
# tests/arch-package-test.sh instead of the install test. Works with podman or
# docker, as root or rootless; no paddock instances are created.
#
# Environment overrides:
#   PD_ENGINE         container engine (default: podman, else docker)
#   PD_ENGINE_ARGS    extra 'run' arguments, e.g. --network=host
#   PD_TEST_CA        CA certificate to trust in the container (TLS-intercepting proxy)
# HTTP(S)_PROXY / NO_PROXY are passed through when set.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$HERE")
ENGINE=${PD_ENGINE:-$(command -v podman || command -v docker || true)}
[[ -n $ENGINE ]] || { echo "need podman or docker" >&2; exit 2; }

image() {
  case $1 in
    ubuntu) echo docker.io/library/ubuntu:24.04 ;;
    debian) echo docker.io/library/debian:13 ;;
    arch|arch-pkg) echo docker.io/library/archlinux:latest ;;
    fedora) echo registry.fedoraproject.org/fedora:latest ;;
    *) return 1 ;;
  esac
}

(($#)) || set -- ubuntu arch
declare -a args=(--rm -v "$REPO:/src:ro" -e SRC=/src)
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
  [[ -n ${!v-} ]] && args+=(-e "$v")
done
[[ -n ${PD_TEST_CA-} ]] && args+=(-v "$PD_TEST_CA:/ca.crt:ro")
# shellcheck disable=SC2206
[[ -n ${PD_ENGINE_ARGS-} ]] && args+=($PD_ENGINE_ARGS)

declare -a failed=()
for d in "$@"; do
  img=$(image "$d") || { echo "unknown distro '$d' (ubuntu, debian, arch, fedora, arch-pkg)" >&2; exit 2; }
  test=install-test.sh; [[ $d == arch-pkg ]] && test=arch-package-test.sh
  printf '\n######## %s (%s)\n' "$d" "$img"
  "$ENGINE" run "${args[@]}" "$img" bash "/src/tests/$test" || failed+=("$d")
done

printf '\n'
if ((${#failed[@]})); then echo "install tests failed on: ${failed[*]}"; exit 1; fi
echo "install tests passed on: $*"
