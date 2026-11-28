#!/usr/bin/env bash
# Copyright (C) 2026 Tim Teichmann
# SPDX-License-Identifier: GPL-2.0-or-later
# Helpers are invoked indirectly through check/check_not:
# shellcheck disable=SC2317
# paddock acceptance tests. Run as a normal user after `paddock build`.
#
#   tests/acceptance.sh
#
# Creates throwaway instances t1/t2 with workspaces /tmp/pd-t1 and /tmp/pd-t2,
# runs the spec's acceptance tests and removes everything again.
#
# Environment overrides:
#   PADDOCK            path to the paddock executable (default: ../paddock)
#   PD_TEST_DENIED     domain used for allow/deny toggling (default: example.com)
#   PD_TEST_DOMAIN2    extra domain only t2 may reach (default: example.org)
#   PD_TEST_PUBLIC_DNS 1 = also check that an allowlisted public name resolving
#                      to 192.168.1.1 (via nip.io) is denied (default: 1)
#   PD_TEST_KEEP       1 = keep instances on failure for debugging

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PADDOCK=${PADDOCK:-$HERE/../paddock}
DENIED=${PD_TEST_DENIED:-example.com}
DOMAIN2=${PD_TEST_DOMAIN2:-example.org}
PUBLIC_DNS=${PD_TEST_PUBLIC_DNS:-1}
T1=t1 T2=t2  # t3 is used for the extra checks
WS1=/tmp/pd-t1 WS2=/tmp/pd-t2
MARK="paddock-test-marker-$$-$RANDOM"
HOME_MARK="$HOME/.$MARK"

PASS=0 FAIL=0 SKIP=0
declare -a FAILED=()

c_g=$'\033[32m' c_r=$'\033[31m' c_y=$'\033[33m' c_0=$'\033[0m'
[[ -t 1 ]] || { c_g=; c_r=; c_y=; c_0=; }

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$c_g" "$c_0" "$*"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$CUR: $*"); printf '  %sFAIL%s %s\n' "$c_r" "$c_0" "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s %s\n' "$c_y" "$c_0" "$*"; }
section() { CUR=$1; printf '\n== %s\n' "$*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

pd() { "$PADDOCK" "$@"; }
ax() { local i=$1; shift; podman exec "pd-$i-agent" "$@"; }

# HTTP status of a request from the agent through its proxy ("000" = none).
http_code() { ax "$1" curl -s -o /dev/null -I -m 20 -w '%{http_code}' "$2" 2>/dev/null; }
# Status the proxy answered a CONNECT with (403 = denied by paddock).
connect_code() { ax "$1" curl -s -o /dev/null -I -m 20 -w '%{http_connect}' "$2" 2>/dev/null; }
got_response() { local c; c=$(http_code "$1" "$2"); [[ -n $c && $c != 000 ]]; }
proxy_denied() { [[ $(connect_code "$1" "$2") == 403 ]]; }
# paddock's own verdict for the most recent request to a domain.
verdict() { pd logs "$1" | awk -v d="$2" '$4 == d":443" || $4 == d":80" { v = $2 } END { print v }'; }
started_at() { podman inspect --format '{{.State.StartedAt}}' "$1"; }
retry() { local n=$1; shift; local i; for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 1; done; return 1; }
labelled_objects() {
  podman ps -a -q --filter "label=paddock.instance=$1"
  podman volume ls -q --filter "label=paddock.instance=$1"
  podman network ls -q --filter "label=paddock.instance=$1"
}
# True if the agent has no network path at all to ip:port (not merely "refused"
# or an HTTP error from something that answered).
no_path() {
  local out rc
  out=$(ax "$1" timeout 8 bash -c "exec 3<>/dev/tcp/$2/$3" 2>&1); rc=$?
  ((rc != 0)) && ! grep -qi 'refused' <<<"$out"
}
proxy_ip() { podman inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{if eq $k "pd-'"$1"'-int"}}{{$v.IPAddress}}{{end}}{{end}}' "pd-$1-proxy"; }
cfg_dir() { printf '%s/paddock' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# The purge test removes the paddock images and config dir. It keeps them by
# tagging the images under a backup name first (podman keeps the layers) and
# copying the config dir; purge_restore puts both back, also from cleanup.
PURGE_CFG_BAK=""
declare -a PURGE_TAGS=()
bak_tag() { printf 'localhost/pdtest-bak-%s' "${1#localhost/}"; }
purge_restore() {
  local t
  for t in "${PURGE_TAGS[@]}"; do
    podman tag "$(bak_tag "$t")" "$t" >/dev/null 2>&1 && podman rmi "$(bak_tag "$t")" >/dev/null 2>&1
  done
  PURGE_TAGS=()
  if [[ -n $PURGE_CFG_BAK ]]; then
    rm -rf "$(cfg_dir)" && cp -a "$PURGE_CFG_BAK" "$(cfg_dir)" && rm -rf "$PURGE_CFG_BAK"
    PURGE_CFG_BAK=""
  fi
}
paddock_images() { podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/paddock-'; }
# Instances other than the given ones: configured, or with podman objects left.
other_instances() {
  local keep=" $* "
  {
    ls "$(cfg_dir)/instances" 2>/dev/null
    podman ps -a --filter label=paddock.instance --format '{{.Names}}' | sed -nE 's/^pd-(.+)-(agent|proxy)$/\1/p'
    podman volume ls --filter label=paddock.instance --format '{{.Name}}' | sed -nE 's/^pd-(.+)-home$/\1/p'
    podman network ls --filter label=paddock.instance --format '{{.Name}}' | sed -nE 's/^pd-(.+)-(int|ext)$/\1/p'
  } | sort -u | while read -r n; do [[ -n $n && $keep != *" $n "* ]] && echo "$n"; done
}

cleanup() {
  local rc=$?
  purge_restore
  if [[ ${PD_TEST_KEEP:-0} == 1 && $FAIL -gt 0 ]]; then
    echo "PD_TEST_KEEP=1: leaving $T1/$T2 in place"; return "$rc"
  fi
  pd rm "$T1" --force >/dev/null 2>&1
  pd rm "$T2" --force >/dev/null 2>&1
  pd rm t3 --force >/dev/null 2>&1
  rm -f "$HOME_MARK"
  [[ -n ${CREATED_WS1-} ]] && rm -rf "$WS1"
  [[ -n ${CREATED_WS2-} ]] && rm -rf "$WS2"
  rm -rf /tmp/pd-t3
  return "$rc"
}

# ------------------------------------------------------------- preflight --
[[ -x $PADDOCK ]] || { echo "paddock not found at $PADDOCK" >&2; exit 2; }
command -v podman >/dev/null || { echo "podman not installed" >&2; exit 2; }
for i in $T1 $T2; do
  [[ -d $(cfg_dir)/instances/$i ]] && { echo "instance $i already exists; remove it first" >&2; exit 2; }
done
for w in $WS1 $WS2; do
  [[ -e $w ]] && { echo "$w already exists; remove it first" >&2; exit 2; }
done
trap cleanup EXIT
CREATED_WS1=1 CREATED_WS2=1

# ---------------------------------------------------------------- tests --
section "11. runs as a normal user (checked up front)"
check_not "not running as root (EUID=$EUID)" test "$EUID" -eq 0
check "podman is rootless" test "$(podman info --format '{{.Host.Security.Rootless}}')" = true
# Quoted strings are dropped first: `paddock doctor` prints "sudo ..." fix hints.
check_not "paddock never invokes sudo" bash -c "grep -vE '^[[:space:]]*#' '$PADDOCK' | sed -E 's/\"[^\"]*\"//g' | grep -qE '(^|[^a-z_])sudo[[:space:]]'"

section "1. create + start + list"
check "create claude $T1 $WS1 --domains pypi.org" pd create claude "$T1" "$WS1" --domains pypi.org
check "start $T1" pd start "$T1"
check "start is idempotent" pd start "$T1"
check "list shows $T1 running" bash -c "'$PADDOCK' list | awk '\$1==\"$T1\" {print \$2}' | grep -qx running"

section "2. allowlist enforced by the proxy"
check "https://api.anthropic.com gets an HTTP response" got_response "$T1" https://api.anthropic.com
check "https://$DENIED is denied by the proxy (403)" proxy_denied "$T1" "https://$DENIED"
check "plain http://$DENIED is denied (403)" test "$(http_code "$T1" "http://$DENIED")" = 403
check "allowlisted domain on a non-443 port is denied" proxy_denied "$T1" https://api.anthropic.com:8443
check "proxy log records the denial" test "$(verdict "$T1" "$DENIED")" = DENIED

section "3. no route around the proxy"
check_not "curl --noproxy '*' https://api.anthropic.com fails" \
  ax "$T1" curl -s --noproxy '*' -m 10 -o /dev/null https://api.anthropic.com
check_not "direct connection to 1.1.1.1:443 fails" \
  ax "$T1" timeout 10 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'
check_not "curl --noproxy '*' https://1.1.1.1 fails" \
  ax "$T1" curl -s --noproxy '*' -m 10 -o /dev/null https://1.1.1.1
check "agent has no default route" bash -c "! podman exec pd-$T1-agent cat /proc/net/route | awk 'NR>1 && \$2==\"00000000\"' | grep -q ."

section "4. host and LAN are unreachable through the proxy"
EXT_GW=$(podman network inspect --format '{{range .Subnets}}{{.Gateway}} {{end}}' "pd-$T1-ext" | awk '{print $1}')
HOST_IP=$(podman exec "pd-$T1-proxy" getent hosts host.containers.internal | awk '{print $1}')
for ip in $EXT_GW $HOST_IP 192.168.1.1; do
  check "http://$ip/ via proxy denied (403)" test "$(http_code "$T1" "http://$ip/")" = 403
  check "https://$ip/ via proxy denied (403)" proxy_denied "$T1" "https://$ip/"
done
# Even an allowlisted *name* is denied when it resolves to a private/host address.
pd domains "$T1" add host.containers.internal >/dev/null 2>&1
sleep 1
check "allowlisted host.containers.internal ($HOST_IP) still denied" \
  test "$(http_code "$T1" "http://host.containers.internal/")" = 403
check "... and the denial came from paddock's proxy" \
  test "$(verdict "$T1" host.containers.internal)" = DENIED
pd domains "$T1" rm host.containers.internal >/dev/null 2>&1
if [[ $PUBLIC_DNS == 1 ]]; then
  pd domains "$T1" add .nip.io >/dev/null 2>&1; sleep 1
  code=$(http_code "$T1" "http://192-168-1-1.nip.io/")
  if [[ $code == 403 && $(verdict "$T1" 192-168-1-1.nip.io) == DENIED ]]; then pass "allowlisted 192-168-1-1.nip.io (-> 192.168.1.1) denied"
  elif [[ $code == 503 ]]; then skip "nip.io did not resolve (no public DNS?)"
  else fail "allowlisted 192-168-1-1.nip.io (-> 192.168.1.1) not denied (got $code)"; fi
  pd domains "$T1" rm .nip.io >/dev/null 2>&1
else
  skip "public-DNS private-IP check (PD_TEST_PUBLIC_DNS=0)"
fi

section "5. live allowlist changes"
A0=$(started_at "pd-$T1-agent"); P0=$(started_at "pd-$T1-proxy")
check "domains add $DENIED" pd domains "$T1" add "$DENIED"
check "https://$DENIED now gets an HTTP response" retry 10 got_response "$T1" "https://$DENIED"
check "domains rm $DENIED" pd domains "$T1" rm "$DENIED"
check "https://$DENIED denied again" retry 10 proxy_denied "$T1" "https://$DENIED"
check "agent container was not restarted" test "$(started_at "pd-$T1-agent")" = "$A0"
check "proxy container was not restarted" test "$(started_at "pd-$T1-proxy")" = "$P0"
check_not "domains add rejects an IP" pd domains "$T1" add 1.2.3.4
check_not "domains add rejects a URL" pd domains "$T1" add https://example.net/x
check_not "domains add rejects a port" pd domains "$T1" add example.net:443
check_not "domains add rejects a glob" pd domains "$T1" add '*.example.net'
printf 'a.example.net b.example.net # two on a line\n' >>"$(cfg_dir)/instances/$T1/domains.txt"
check "domains on one line are read as separate entries" \
  bash -c "'$PADDOCK' domains $T1 list | grep -qE '^instance +a\.example\.net$' && '$PADDOCK' domains $T1 list | grep -qE '^instance +b\.example\.net$'"
pd domains "$T1" rm a.example.net b.example.net >/dev/null 2>&1
check_not "logs -n 0 is refused" pd logs "$T1" -n 0
check_not "logs -n x is refused" pd logs "$T1" -n x
check "logs -n 1 prints one line" test "$(pd logs "$T1" -n 1 | wc -l)" -eq 1

section "6. workspace ownership"
check "agent creates /workspace/from-agent" ax "$T1" sh -c 'echo agent > /workspace/from-agent'
check "from-agent owned by host user ($(id -u):$(id -g))" \
  test "$(stat -c %u:%g "$WS1/from-agent" 2>/dev/null)" = "$(id -u):$(id -g)"
echo host >"$WS1/from-host"
check "host file readable inside" test "$(ax "$T1" cat /workspace/from-host)" = host
check "host file writable inside" ax "$T1" sh -c 'echo agent-was-here >> /workspace/from-host'
check "write visible on host" grep -qx agent-was-here "$WS1/from-host"
check "from-host still owned by host user" test "$(stat -c %u "$WS1/from-host")" = "$(id -u)"

section "7. no host data inside the agent"
echo secret >"$HOME_MARK"
check_not "marker file from host \$HOME not found anywhere in agent" \
  bash -c "podman exec pd-$T1-agent find / \\( -path /proc -o -path /sys \\) -prune -o -name '.$MARK' -print 2>/dev/null | grep -q ."
check_not "host \$HOME ($HOME) not listable with contents" \
  bash -c "podman exec pd-$T1-agent ls -A '$HOME' 2>/dev/null | grep -q ."
check_not "ls /run/user shows nothing" bash -c "podman exec pd-$T1-agent ls -A /run/user 2>/dev/null | grep -q ."
check_not "ls ~/.ssh shows nothing" bash -c "podman exec pd-$T1-agent sh -c 'ls -A ~/.ssh' 2>/dev/null | grep -q ."
check_not "no socket files anywhere (podman/ssh-agent/dbus/X11/wayland)" \
  bash -c "podman exec pd-$T1-agent find / \\( -path /proc -o -path /sys \\) -prune -o -type s -print 2>/dev/null | grep -q ."
check_not "no session/socket env vars (SSH_AUTH_SOCK, DBUS, DISPLAY, ...)" \
  bash -c "podman exec pd-$T1-agent env | grep -qE '^(SSH_AUTH_SOCK|DBUS_SESSION_BUS_ADDRESS|WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR)='"
check "agent has the tool's env (tools/claude/env)" \
  bash -c "podman exec pd-$T1-agent env | grep -qx DISABLE_AUTOUPDATER=1"
check "domains list shows the tool's domains" \
  bash -c "'$PADDOCK' domains $T1 list | grep -qE '^tool +api\\.anthropic\\.com$'"
check_not "no git credentials or forge URL rewrites in the agent" \
  bash -c "podman exec pd-$T1-agent git config --show-origin --list 2>/dev/null | grep -qiE 'credential|insteadof'"
check_not "paddock config dir not mounted" \
  bash -c "podman exec pd-$T1-agent cat /proc/self/mountinfo | grep -qF '$(cfg_dir)'"
check "only the workspace (and paths in it) is bind-mounted" \
  bash -c "podman inspect --format '{{range .Mounts}}{{.Type}}={{.Source}}{{\"\\n\"}}{{end}}' pd-$T1-agent | grep '^bind=' | grep -vxF 'bind=$WS1' | grep -vF 'bind=$WS1/' | grep -vE '^bind=.*/(userdata|containers/storage)/' | grep -q . && exit 1 || exit 0"

section "8. two concurrent instances"
check "create claude $T2 $WS2 --domains $DOMAIN2" pd create claude "$T2" "$WS2" --domains "$DOMAIN2"
check "start $T2" pd start "$T2"
echo t2-secret >"$WS2/$MARK-t2"
echo t1-secret >"$WS1/$MARK-t1"
check "both running" bash -c "'$PADDOCK' list | awk '\$1==\"$T1\"||\$1==\"$T2\" {print \$2}' | grep -c running | grep -qx 2"
check_not "$T1 cannot see $T2's workspace" \
  bash -c "podman exec pd-$T1-agent find / \\( -path /proc -o -path /sys \\) -prune -o -name '$MARK-t2' -print 2>/dev/null | grep -q ."
check_not "$T2 cannot see $T1's workspace" \
  bash -c "podman exec pd-$T2-agent find / \\( -path /proc -o -path /sys \\) -prune -o -name '$MARK-t1' -print 2>/dev/null | grep -q ."
P1=$(proxy_ip "$T1"); P2=$(proxy_ip "$T2")
A2=$(podman inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "pd-$T2-agent")
check "$T1 has no path to $T2's proxy ($P2:3128)" no_path "$T1" "$P2" 3128
check "$T2 has no path to $T1's proxy ($P1:3128)" no_path "$T2" "$P1" 3128
check "$T1 has no path to $T2's agent ($A2)" no_path "$T1" "$A2" 22
check "control: $T1 does reach its own proxy ($P1:3128)" ax "$T1" timeout 8 bash -c "exec 3<>/dev/tcp/$P1/3128"
connect_code "$T1" "https://$DOMAIN2" >/dev/null
check "$DOMAIN2 denied for $T1" test "$(verdict "$T1" "$DOMAIN2")" = DENIED
connect_code "$T2" "https://$DOMAIN2" >/dev/null
check "$DOMAIN2 allowed for $T2" test "$(verdict "$T2" "$DOMAIN2")" = ALLOWED
check "$T2 still allows base domains" got_response "$T2" https://api.anthropic.com

section "9. rm keeps the workspace"
check "rm $T1 --force" pd rm "$T1" --force
check_not "no podman objects labelled $T1 remain" bash -c "$(declare -f labelled_objects); labelled_objects $T1 | grep -q ."
check_not "no pd-$T1-* containers remain" bash -c "podman ps -a --format '{{.Names}}' | grep -q '^pd-$T1-'"
check_not "config dir removed" test -e "$(cfg_dir)/instances/$T1"
check "$WS1 still exists with its files" test -f "$WS1/from-agent" -a -f "$WS1/from-host"
check "$T2 unaffected" bash -c "'$PADDOCK' list | awk '\$1==\"$T2\" {print \$2}' | grep -qx running"

section "10. dangerous workspace paths refused"
check_not "create refuses \$HOME" pd create claude tbad "$HOME"
check_not "create refuses /" pd create claude tbad /
check_not "create refuses a parent of \$HOME ($(dirname "$HOME"))" pd create claude tbad "$(dirname "$HOME")"
check_not "create refuses the paddock config dir" pd create claude tbad "$(cfg_dir)/x"
check_not "create refuses a hidden dir of \$HOME" pd create claude tbad "$HOME/.pd-test-$MARK"
check_not "... and did not create it" test -e "$HOME/.pd-test-$MARK"
check_not "create refuses the paddock script's dir" pd create claude tbad "$(dirname "$(realpath "$PADDOCK")")"
check_not "create refuses Podman's storage" pd create claude tbad "$(podman info --format '{{.Store.GraphRoot}}')/x"
check_not "create refuses a workspace inside $T2's ($WS2/sub)" pd create claude tbad "$WS2/sub"
check_not "create refuses a workspace containing $T2's (/tmp)" pd create claude tbad /tmp
check_not "create refuses an invalid name" pd create claude Bad_Name /tmp/pd-bad
check_not "create refuses an unknown tool" pd create nosuchtool tbad /tmp/pd-bad
check_not "no instance 'tbad' was created" test -e "$(cfg_dir)/instances/tbad"

section "extra: create without --domains, recreate"
check "create claude t3 /tmp/pd-t1/sub (no --domains)" pd create claude t3 "$WS1/sub"
check "start t3" pd start t3
check "recreate t3 keeps working" bash -c "'$PADDOCK' recreate t3 && '$PADDOCK' start t3"
check "rm t3" pd rm t3 --force

section "extra: agent instructions (PADDOCK.md)"
WS3=/tmp/pd-t3
rm -rf "$WS3"
check "create claude t3 $WS3" pd create claude t3 "$WS3"
check_not "no AGENTS.md written into the workspace" test -e "$WS3/AGENTS.md"
check "start t3" pd start t3
check "PADDOCK.md readable in the agent" ax t3 grep -qF 'paddock domains' /etc/paddock/PADDOCK.md
check "Claude Code's managed CLAUDE.md is PADDOCK.md" ax t3 sh -c 'test "$(sha256sum </etc/paddock/PADDOCK.md)" = "$(sha256sum </etc/claude-code/CLAUDE.md)"'
check_not "agent cannot change it" ax t3 sh -c 'echo x >> /etc/claude-code/CLAUDE.md'
check "PADDOCK_INSTANCE is set in the agent" test "$(ax t3 printenv PADDOCK_INSTANCE)" = t3
check "rm t3" pd rm t3 --force
check "create --no-agents-md still works (ignored, warns)" bash -c "'$PADDOCK' create claude t3 '$WS3' --no-agents-md 2>&1 | grep -q 'no longer needed'"
check "rm t3" pd rm t3 --force
rm -rf "$WS3"

section "extra: git protection"
WS3=/tmp/pd-t3
rm -rf "$WS3"; mkdir -p "$WS3"
if ! command -v git >/dev/null; then
  skip "git protection tests: git not installed on the host"
else
  git -C "$WS3" init -q
  cfg_sum=$(sha256sum <"$WS3/.git/config")
  check "create claude t3 on a git repo" pd create claude t3 "$WS3"
  check "start t3" pd start t3
  ax t3 git config --global user.name test >/dev/null 2>&1
  ax t3 git config --global user.email test@example.invalid >/dev/null 2>&1
  check "agent can commit" ax t3 sh -c 'cd /workspace && echo x > f && git add f && git commit -qm test'
  check "agent can create and switch branches" ax t3 sh -c 'cd /workspace && git switch -qc b2 && git switch -q -'
  check "commit visible on the host" test "$(git -C "$WS3" log --format=%s -1)" = test
  check_not "agent cannot write .git/config" ax t3 git -C /workspace config core.fsmonitor 'touch /tmp/x'
  check_not "agent cannot add a hook" ax t3 sh -c 'echo "#!/bin/sh" > /workspace/.git/hooks/pre-commit'
  check_not "agent cannot replace .git/config" ax t3 sh -c 'cp /workspace/.git/config /tmp/c && mv /tmp/c /workspace/.git/config'
  check_not "agent cannot move .git aside" ax t3 mv /workspace/.git /workspace/.git-old
  check_not "agent cannot move hooks aside" ax t3 mv /workspace/.git/hooks /workspace/.git/hooks-old
  check ".git/config unchanged on the host" test "$(sha256sum <"$WS3/.git/config")" = "$cfg_sum"
  check_not "no hooks on the host" test -e "$WS3/.git/hooks/pre-commit"
  ax t3 touch /workspace/.git/commondir
  check "stop warns about .git/commondir" bash -c "'$PADDOCK' stop t3 2>&1 | grep -q commondir"
  rm -f "$WS3/.git/commondir"
  check "stop does not warn about nested repositories yet" bash -c "! '$PADDOCK' stop t3 2>&1 | grep -q 'nested git'"
  pd start t3 >/dev/null 2>&1
  ax t3 git -C /workspace init -q sub >/dev/null 2>&1
  check "stop warns about a nested repository" bash -c "'$PADDOCK' stop t3 2>&1 | grep -q 'nested git repositories.*sub/.git'"
  rm -rf "$WS3/sub"
  pd start t3 >/dev/null 2>&1
  ax t3 sh -c 'mkdir -p /workspace/.git/modules/m && echo "[core]" > /workspace/.git/modules/m/config' >/dev/null 2>&1
  check "stop warns about .git/modules" bash -c "'$PADDOCK' stop t3 2>&1 | grep -q '.git/modules has submodule'"
  rm -rf "$WS3/.git/modules"
  check "rm t3" pd rm t3 --force
  git -C "$WS3" config extensions.worktreeConfig true
  check "create claude t3 with extensions.worktreeConfig" pd create claude t3 "$WS3"
  check "start t3" pd start t3
  check_not "agent cannot write .git/config.worktree" ax t3 sh -c 'echo "[core] fsmonitor = x" >> /workspace/.git/config.worktree'
  check "rm t3" pd rm t3 --force
  git -C "$WS3" config --unset extensions.worktreeConfig
  rm -rf "$WS3/.git"
  check "create claude t3 without a repo" pd create claude t3 "$WS3"
  check "start t3" pd start t3
  ax t3 git -C /workspace init -q >/dev/null 2>&1
  check "start warns about an unprotected .git" bash -c "'$PADDOCK' start t3 2>&1 | grep -q 'not mounted read-only'"
  check "recreate protects it" bash -c "'$PADDOCK' recreate t3 >/dev/null 2>&1 && ! '$PADDOCK' start t3 2>&1 | grep -q 'not mounted read-only' && ! podman exec pd-t3-agent touch /workspace/.git/hooks/x"
  check "rm t3" pd rm t3 --force
fi
rm -rf "$WS3"

section "extra: protected tool settings"
WS3=/tmp/pd-t3
rm -rf "$WS3"; mkdir -p "$WS3"
check "create claude t3" pd create claude t3 "$WS3"
check ".claude created in the workspace" test -d "$WS3/.claude"
check "start t3" pd start t3
check_not "agent cannot write .claude/settings.json" ax t3 sh -c 'echo "{}" > /workspace/.claude/settings.json'
check_not "agent cannot move .claude aside" ax t3 mv /workspace/.claude /workspace/.claude-old
check "agent can write its own ~/.claude/settings.json" ax t3 sh -c 'mkdir -p ~/.claude && echo "{}" > ~/.claude/settings.json'
check "agent can create .mcp.json (missing at create)" ax t3 sh -c 'echo "{}" > /workspace/.mcp.json'
check "stop warns about the unprotected .mcp.json" bash -c "'$PADDOCK' stop t3 2>&1 | grep -q '.mcp.json is not mounted read-only'"
check "recreate protects it" bash -c "'$PADDOCK' recreate t3 >/dev/null 2>&1 && '$PADDOCK' start t3 >/dev/null 2>&1"
check_not "agent cannot write .mcp.json after recreate" ax t3 sh -c 'echo "{}" >> /workspace/.mcp.json'
check_not "start no longer warns" bash -c "'$PADDOCK' start t3 2>&1 | grep -q 'not mounted read-only'"
pd stop t3 >/dev/null 2>&1; rmdir "$WS3/.claude"
check "start re-creates a removed .claude" bash -c "'$PADDOCK' start t3 && test -d '$WS3/.claude'"
check "rm t3" pd rm t3 --force
rm -rf "$WS3"

section "extra: workspace path changes"
mkdir -p /tmp/pd-t3/ws
check "create claude t3 /tmp/pd-t3/ws" pd create claude t3 /tmp/pd-t3/ws
mv /tmp/pd-t3/ws /tmp/pd-t3/ws2 && ln -s ws2 /tmp/pd-t3/ws
check_not "start refuses a workspace that now resolves elsewhere" pd start t3
check_not "recreate refuses it too" pd recreate t3
rm /tmp/pd-t3/ws && mv /tmp/pd-t3/ws2 /tmp/pd-t3/ws
check "start works again with the original directory" pd start t3
check "rm t3" pd rm t3 --force
rm -rf /tmp/pd-t3

section "extra: per-instance packages"
WS3=/tmp/pd-t3
rm -rf "$WS3"
check_not "create refuses an invalid package name" pd create claude t3 "$WS3" --packages '-rf'
check_not "... and creates no instance" test -e "$(cfg_dir)/instances/t3"
check_not "create with an unknown package fails" pd create claude t3 "$WS3" --packages paddock-no-such-package
check_not "... and rolls back" test -e "$(cfg_dir)/instances/t3"
check "create claude t3 --packages jq" pd create claude t3 "$WS3" --packages jq
check "instance image built" podman image exists localhost/paddock-inst:t3
check "start t3" pd start t3
check "jq installed in t3" ax t3 jq --version
check_not "jq not in $T2 (tool image)" ax "$T2" sh -c 'command -v jq'
check "list shows 1 package" bash -c "'$PADDOCK' list | awk '\$1==\"t3\" {print \$5}' | grep -qx 1"
check_not "packages add of an unknown package fails" pd packages t3 add paddock-no-such-package
check "... and leaves the list unchanged" test "$(pd packages t3 list)" = jq
check "packages add tree" pd packages t3 add tree
check "packages list shows jq and tree" test "$(pd packages t3 list | paste -sd,)" = jq,tree
check "start warns until recreate" bash -c "'$PADDOCK' start t3 2>&1 | grep -q 'packages of .t3. changed'"
check "recreate t3" pd recreate t3
check "start t3, no warning" bash -c "! '$PADDOCK' start t3 2>&1 | grep -q 'packages of'"
check "tree installed after recreate" ax t3 tree --version
check_not "setuid bits stripped in the instance image" ax t3 sh -c 'find / -xdev -perm /6000 -type f 2>/dev/null | grep -q .'
check "packages rm jq tree" pd packages t3 rm jq tree
check "recreate t3 without packages" bash -c "'$PADDOCK' recreate t3 && '$PADDOCK' start t3"
check_not "instance image removed" podman image exists localhost/paddock-inst:t3
check_not "jq gone" ax t3 sh -c 'command -v jq'
check "packages add jq again" bash -c "'$PADDOCK' packages t3 add jq && '$PADDOCK' recreate t3"
check "rm t3" pd rm t3 --force
check_not "rm removes the instance image" podman image exists localhost/paddock-inst:t3
check_not "... and earlier untagged builds" bash -c "podman images -q --filter label=paddock.instance=t3 | grep -q ."
rm -rf "$WS3"

section "extra: purge"
# purge removes *all* instances of this user, so it only runs when no
# instances other than the test's own exist.
others=$(other_instances "$T2" t3 | paste -sd' ')
if [[ -n $others ]]; then
  skip "purge test: other paddock instances exist ($others)"
else
  WS3=/tmp/pd-t3
  rm -rf "$WS3"
  pd create claude t3 "$WS3" >/dev/null 2>&1 && pd start t3 >/dev/null 2>&1
  PURGE_CFG_BAK=$(mktemp -d)/paddock
  cp -a "$(cfg_dir)" "$PURGE_CFG_BAK"
  mapfile -t PURGE_TAGS < <(paddock_images)
  for t in "${PURGE_TAGS[@]}"; do podman tag "$t" "$(bak_tag "$t")"; done
  check "images present before purge (${#PURGE_TAGS[@]})" test "${#PURGE_TAGS[@]}" -gt 0
  # Leave $T2's podman objects without a config: purge must still find them.
  rm -rf "$(cfg_dir)/instances/$T2"
  out=$(setsid -w "$PADDOCK" purge </dev/null 2>&1)
  check_not "purge without a terminal refuses (needs --force)" setsid -w "$PADDOCK" purge
  check "... after listing t3, the images and the config dir" \
    bash -c "grep -q 'instance t3 ' <<<\"\$1\" && grep -q 'image    localhost/paddock-' <<<\"\$1\" && grep -qF 'config   $(cfg_dir)' <<<\"\$1\"" _ "$out"
  check "... including $T2, whose config is gone" bash -c "grep -q 'instance $T2 .*no config left' <<<\"\$1\"" _ "$out"
  check "... and removes nothing" bash -c "'$PADDOCK' list | awk '\$1==\"t3\" {print \$2}' | grep -qx running && podman container exists pd-$T2-agent"
  check "purge --force --keep-images" pd purge --force --keep-images
  check_not "no labelled containers, volumes or networks remain" \
    bash -c "$(declare -f other_instances cfg_dir); other_instances | grep -q ."
  check_not "config dir removed" test -e "$(cfg_dir)"
  check "workspaces kept" test -d "$WS3" -a -d "$WS2"
  check "--keep-images kept the images" test "$(paddock_images | wc -l)" -eq "${#PURGE_TAGS[@]}"
  check "purge --force removes the images" pd purge --force
  check_not "no localhost/paddock-* images remain" bash -c "$(declare -f paddock_images); paddock_images | grep -q ."
  check "other images kept (backup tags)" podman image exists "$(bak_tag "${PURGE_TAGS[0]}")"
  check_not "config dir not recreated" test -e "$(cfg_dir)"
  check "purge again: nothing to purge" bash -c "'$PADDOCK' purge --force 2>&1 | grep -q 'nothing to purge'"
  purge_restore
  check "images and config restored" bash -c "'$PADDOCK' tools | grep -qv 'not built'"
  rm -rf "$WS3"
fi

# --------------------------------------------------------------- summary --
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL)); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
