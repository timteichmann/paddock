# paddock

Isolated coding-agent instances (Claude Code first) on rootless Podman. Each
instance sees exactly one host directory and can reach only an allowlist of
domains, enforced by a per-instance Squid proxy that is the agent's only way out.

```
            host (your user, rootless podman)
 ┌──────────────────────────────────────────────────────────┐
 │  pd-<n>-int  (--internal, --disable-dns, isolate)         │
 │  ┌──────────────┐  HTTP(S)_PROXY   ┌──────────────┐       │   pd-<n>-ext
 │  │ pd-<n>-agent │ ───────────────▶ │ pd-<n>-proxy │ ──────┼──▶ internet
 │  │ /workspace   │   :3128 only     │ Squid        │       │   (allowlist)
 │  └──────────────┘                  └──────────────┘       │
 │   bind: <path>  vol: pd-<n>-home    ro: instances/<n>/proxy│
 └──────────────────────────────────────────────────────────┘
```

## Requirements

Arch Linux (or any distro with Podman ≥ 4.4 and netavark), rootless Podman with
subuid/subgid configured, bash ≥ 4.4, curl. cgroup v2 delegation (Arch default)
for the memory/CPU/pids limits. No root and no sudo at runtime.

```bash
sudo pacman -S podman
```

## Images

Both images are built from `archlinux:latest`. The agent image has bash, git,
ripgrep, curl, python, nodejs/npm, and Claude Code at a pinned version from
npm (`paddock build --version X`; without `--version`, the latest version is
resolved and pinned). No sudo is installed, and setuid bits are stripped.
The agent runs with `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reporting
or update checks), so only the allowlisted API and login hosts are contacted.

The Containerfiles are written to `~/.config/paddock/` on first run and can be
edited there. Arch is rolling, so a rebuild picks up current packages.

## Install

```bash
install -Dm755 paddock ~/.local/bin/paddock
```

## Quick start

```bash
paddock build                       # builds paddock-proxy and paddock-agent:<latest>
paddock create web ~/src/web --domains pypi.org,.githubusercontent.com
paddock attach web                  # starts if needed, runs claude in /workspace
```

Log in once with `/login` inside Claude Code; the login lives in the instance's
own home volume `pd-web-home` and survives `stop`/`start` and `recreate`
(but not `rm`).

## Commands

| Command | |
| --- | --- |
| `create <name> <path> [--domains d1,d2]` | create (not started). Refuses `/`, `$HOME`, parents of `$HOME`, and the paddock config dir |
| `start <name>` / `stop <name>` | idempotent; proxy first, then agent |
| `attach <name> [--yolo] [-- claude args]` | `--yolo` adds `--dangerously-skip-permissions` (prints a warning) |
| `shell <name>` | bash in the agent as the unprivileged user |
| `rm <name> [--force]` | removes containers, networks, home volume and config. Never touches the workspace |
| `recreate <name>` | *(extra)* recreates containers, e.g. after `build` of a new version. Keeps the home volume (login) |
| `list` | name, state, number of extra domains, workspace |
| `domains <name> list\|add\|rm\|edit` | live reload via `squid -k reconfigure`, no restarts |
| `logs <name> [-f] [-n N] [--raw]` | `TIME ALLOWED/DENIED METHOD host:port (squid-code status)` |
| `build [--version X]` | without `--version`, the latest npm version is resolved and pinned |

`attach` and `shell` pass your terminal's `TERM` and `COLORTERM` into the
instance, so Claude Code shows full colors. If the agent image has no terminfo
for your `TERM`, `xterm-256color` is used instead. Over SSH, `COLORTERM` is
usually not forwarded; set `COLORTERM=truecolor` on the host if your terminal
supports it.

Domain syntax: `example.com` (exact) or `.example.com` (domain and subdomains).
IPs, URLs, ports, `*` globs and bare TLDs are rejected. Overlapping entries
(e.g. `example.com` and `.example.com`) are merged automatically because Squid
treats them as fatal.

## Files

```
~/.config/paddock/            (mode 0700, never mounted into the agent)
  config                      limits, relabel flag, pinned agent_version
  base-domains.txt            applies to every instance
  Containerfile.agent         editable; used by `paddock build`
  Containerfile.proxy
  build/                      optional extra build-context files (e.g. a corporate CA)
  squid-extra.conf            optional, included at the end of every squid.conf (e.g. cache_peer)
  instances/<name>/
    workspace                 absolute host path
    domains.txt               per-instance extra domains
    proxy/                    generated: squid.conf + allowlist.txt (mounted read-only into the proxy)
```

`config` settings (empty value disables a limit): `agent_memory=4g`,
`agent_cpus=2`, `agent_pids_limit=2048`, `proxy_memory=256m`, `proxy_cpus=0.5`,
`proxy_pids_limit=256`, `relabel=` (`z`/`Z` on SELinux hosts). Limit changes
take effect on `paddock recreate <name>`.

### Git

The workspace is a bind mount of a host directory, so do all remote git work
(fetch, pull, push, PRs) on the host. Instances get no git credentials and need
no access to GitHub or other forges; `git` in the image is for local commits,
diffs and history in `/workspace`.

## How isolation works

- **Filesystem:** only the workspace is bind-mounted (`/workspace`). Home is a
  per-instance named volume, so one instance cannot plant hooks or settings in
  another. No host sockets, no `$HOME`, no host credentials.
- **Ownership:** `--userns=keep-id --user $UID:$GID`. Files created by the agent
  are owned by you on the host.
- **Network:** the agent is only on `pd-<n>-int` (`--internal`, no gateway, no
  default route, `--disable-dns`, `--dns=none`). It reaches the proxy through a
  static `/etc/hosts` entry, so DNS tunnelling is not available either. Programs
  that ignore `HTTPS_PROXY` simply fail.
- **Proxy:** Squid listens only on its internal-network address. Policy is
  default deny: source must be the instance's subnet; host must be allowlisted
  (`dstdomain -n`, no reverse DNS); `CONNECT` only to 443; plain HTTP only to
  port 80; destinations that resolve to loopback, RFC 1918, CGNAT, link-local,
  documentation/benchmark ranges, multicast, and IPv6 ULA/link-local/mapped/NAT64
  are denied even when the name is allowlisted. No TLS interception.
- **Hardening:** both containers run with `--cap-drop=ALL`, `no-new-privileges`,
  pids/memory/cpu limits, no `--privileged`, no devices, and no host network,
  PID or IPC namespaces. The proxy runs as an unprivileged user on a read-only
  rootfs. The agent image has no sudo, and setuid bits are stripped.

## Tests

```bash
tests/acceptance.sh
```

Creates `t1`/`t2` (workspaces `/tmp/pd-t1`, `/tmp/pd-t2`), runs spec tests 1–11
plus extra checks, and cleans up. Overrides: `PD_TEST_DENIED` (domain toggled in
test 5, default `example.com`), `PD_TEST_DOMAIN2` (default `example.org`),
`PD_TEST_PUBLIC_DNS=0` (skip the nip.io private-IP check), `PD_TEST_KEEP=1`.

## Known limitations

- Exfiltration to allowlisted domains is possible (non-goal). Allowlisting a broad
  domain such as `.githubusercontent.com` or `.amazonaws.com` widens it a lot.
- If the host has a **public** IP and an allowlisted name resolves to it, the
  proxy will connect to it. Private and host-internal addresses are blocked.
- Squid resolves a name once for the policy check and reuses that answer to
  connect, so DNS rebinding is limited to its ipcache behaviour.
- Kernel and Podman escapes are out of scope; use a VM for untrusted code.
