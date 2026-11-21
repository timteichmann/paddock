#!/usr/bin/env bash
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

cleanup() {
  local rc=$?
  if [[ ${PD_TEST_KEEP:-0} == 1 && $FAIL -gt 0 ]]; then
    echo "PD_TEST_KEEP=1: leaving $T1/$T2 in place"; return "$rc"
  fi
  pd rm "$T1" --force >/dev/null 2>&1
  pd rm "$T2" --force >/dev/null 2>&1
  pd rm t3 --force >/dev/null 2>&1
  rm -f "$HOME_MARK"
  [[ -n ${CREATED_WS1-} ]] && rm -rf "$WS1"
  [[ -n ${CREATED_WS2-} ]] && rm -rf "$WS2"
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
check_not "paddock never invokes sudo" bash -c "grep -vE '^[[:space:]]*#' '$PADDOCK' | grep -qE '(^|[^a-z_])sudo[[:space:]]'"

section "1. create + start + list"
check "create $T1 $WS1 --domains pypi.org" pd create "$T1" "$WS1" --domains pypi.org
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
check_not "no host sockets (podman/ssh-agent/dbus/X11/wayland)" \
  bash -c "podman exec pd-$T1-agent sh -c 'ls -A /tmp/.X11-unix /run/podman /run/dbus 2>/dev/null; env | grep -E \"^(SSH_AUTH_SOCK|DBUS_SESSION_BUS_ADDRESS|WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR)=\"' | grep -q ."
check_not "paddock config dir not mounted" \
  bash -c "podman exec pd-$T1-agent cat /proc/self/mountinfo | grep -qF '$(cfg_dir)'"
check "workspace is the only host directory bind-mounted" \
  bash -c "podman inspect --format '{{range .Mounts}}{{.Type}}={{.Source}}{{\"\\n\"}}{{end}}' pd-$T1-agent | grep '^bind=' | grep -vxF 'bind=$WS1' | grep -vE '^bind=.*/(userdata|containers/storage)/' | grep -q . && exit 1 || exit 0"

section "8. two concurrent instances"
check "create $T2 $WS2 --domains $DOMAIN2" pd create "$T2" "$WS2" --domains "$DOMAIN2"
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
check_not "create refuses \$HOME" pd create tbad "$HOME"
check_not "create refuses /" pd create tbad /
check_not "create refuses a parent of \$HOME ($(dirname "$HOME"))" pd create tbad "$(dirname "$HOME")"
check_not "create refuses the paddock config dir" pd create tbad "$(cfg_dir)/x"
check_not "create refuses an invalid name" pd create Bad_Name /tmp/pd-bad
check_not "no instance 'tbad' was created" test -e "$(cfg_dir)/instances/tbad"

section "extra: create without --domains, recreate"
check "create t3 /tmp/pd-t1/sub (no --domains)" pd create t3 "$WS1/sub"
check "start t3" pd start t3
check "recreate t3 keeps working" bash -c "'$PADDOCK' recreate t3 && '$PADDOCK' start t3"
check "rm t3" pd rm t3 --force

# --------------------------------------------------------------- summary --
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL)); then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
