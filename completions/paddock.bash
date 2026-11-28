# bash completion for paddock
# shellcheck shell=bash
# Copyright (C) 2026 Tim Teichmann
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Installed by install.sh to <prefix>/share/bash-completion/completions/paddock,
# where bash-completion loads it on demand. From a checkout:
#   source completions/paddock.bash

_paddock_instances() {
  local d dir="${XDG_CONFIG_HOME:-$HOME/.config}/paddock/instances"
  for d in "$dir"/*/; do
    [[ -d $d ]] && basename "$d"
  done
}

_paddock_tools() {
  # Ask paddock: it knows the data dir and the user's overrides.
  "${COMP_WORDS[0]}" __complete-tools 2>/dev/null
}

_paddock_instance_domains() { # name
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/paddock/instances/$1/domains.txt"
  [[ -f $f ]] && sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$f"
}

_paddock_instance_packages() { # name
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/paddock/instances/$1/packages.txt"
  [[ -f $f ]] && sed -e 's/#.*//' "$f" | tr -s '[:space:]' '\n' | sed '/^$/d'
}

_paddock() {
  local cur prev words cword
  if declare -F _init_completion >/dev/null; then
    _init_completion || return
  else
    cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    words=("${COMP_WORDS[@]}") cword=$COMP_CWORD
  fi

  local cmds="create start attach shell stop rm recreate list ls domains packages logs build tools doctor purge help version"
  if ((cword == 1)); then
    mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
    return
  fi

  local cmd=${words[1]}
  # Position among the non-option arguments after the command, and the
  # arguments seen so far (1-based; the word being completed is $n).
  local i n=0 w
  local -a args=()
  for ((i = 2; i < cword; i++)); do
    w=${words[i]}
    case $w in
      --) break ;;
      -n|--tail|--domains|--packages|--version) ((i++)); continue ;;
      -*) continue ;;
    esac
    args+=("$w")
  done
  n=$((${#args[@]} + 1))
  # Nothing to complete after `attach <name> --`: those args go to the tool.
  for ((i = 2; i < cword; i++)); do [[ ${words[i]} == -- ]] && return; done

  case $prev in
    -n|--tail|--domains|--packages|--version) return ;;
  esac

  local opts="" list=""
  case $cmd in
    create)
      opts="--domains --packages"
      case $n in
        1) list=$(_paddock_tools) ;;
        3) [[ $cur != -* ]] && { compopt -o filenames 2>/dev/null
             mapfile -t COMPREPLY < <(compgen -d -- "$cur"); return; } ;;
      esac ;;
    start|stop|shell|recreate)
      ((n == 1)) && list=$(_paddock_instances) ;;
    attach)
      opts="--yolo --"
      ((n == 1)) && list=$(_paddock_instances) ;;
    rm)
      opts="--force"
      ((n == 1)) && list=$(_paddock_instances) ;;
    logs)
      opts="--follow --tail --raw"
      ((n == 1)) && list=$(_paddock_instances) ;;
    domains)
      case $n in
        1) list=$(_paddock_instances) ;;
        2) list="list add rm edit" ;;
        *) # Offer only domains not already given.
           [[ ${args[1]} == rm ]] && list=$(_paddock_instance_domains "${args[0]}" \
             | grep -vxF -f <(printf '%s\n' "${args[@]:2}") ) ;;
      esac ;;
    packages)
      case $n in
        1) list=$(_paddock_instances) ;;
        2) list="list add rm edit" ;;
        *) [[ ${args[1]} == rm ]] && list=$(_paddock_instance_packages "${args[0]}" \
             | grep -vxF -f <(printf '%s\n' "${args[@]:2}") ) ;;
      esac ;;
    build)
      opts="--version"
      ((n == 1)) && list=$(_paddock_tools) ;;
    purge)
      opts="--force --keep-images" ;;
    *) return ;;
  esac

  if [[ $cur == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
  else
    mapfile -t COMPREPLY < <(compgen -W "$list" -- "$cur")
  fi
}

complete -F _paddock paddock
