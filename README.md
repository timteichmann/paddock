# paddock

Isolated coding-agent instances on rootless Podman. Supported tools: Claude Code
(`claude`); more can be added as tool definitions. Each
instance sees exactly one host directory and can reach only an allowlist of
domains, enforced by a per-instance Squid proxy that is the agent's only way out.

```
            host (your user, rootless podman)
 ┌───────────────────────────────────────────────────────────┐
 │  pd-<n>-int  (--internal, --disable-dns, isolate)         │
 │  ┌──────────────┐  HTTP(S)_PROXY   ┌──────────────┐       │   pd-<n>-ext
 │  │ pd-<n>-agent │ ───────────────> │ pd-<n>-proxy │ ──────┼──> internet
 │  │ /workspace   │   :3128 only     │ Squid        │       │   (allowlist)
 │  └──────────────┘                  └──────────────┘       │
 │   bind: <path>  vol: pd-<n>-home  ro: instances/<n>/proxy │
 └───────────────────────────────────────────────────────────┘
```

## Requirements

Arch Linux (or any distro with Podman ≥ 4.4 and netavark), rootless Podman with
subuid/subgid configured, bash ≥ 4.4, curl. cgroup v2 delegation (Arch default)
for the memory/CPU/pids limits. No root and no sudo at runtime.

```bash
sudo pacman -S podman
```

## Images

All images are built from `archlinux:latest`:

- `paddock-proxy`: Squid only.
- `paddock-base`: bash, git, ripgrep, curl, python and nodejs/npm. No sudo is
  installed, and setuid bits are stripped.
- `paddock-<tool>:<version>`: `FROM paddock-base`, plus the tool at a pinned
  version (`paddock build <tool> --version X`; without `--version`, the latest
  version of the tool's npm package is resolved and pinned).

Claude Code runs with `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reporting
or update checks), so only the allowlisted API and login hosts are contacted.
Arch is rolling, so a rebuild picks up current packages.

## Install

paddock is the `paddock` script plus its data directory `share/` (defaults and
tool definitions):

```bash
install -Dm755 paddock ~/.local/bin/paddock
mkdir -p ~/.local/share/paddock && cp -r share/. ~/.local/share/paddock/
```

paddock looks for the data directory in `$PADDOCK_DATA_DIR`, then `share/` next
to the (symlink-resolved) script, then `~/.local/share/paddock`,
`/usr/local/share/paddock` and `/usr/share/paddock`. Running `./paddock` from a
checkout uses the checkout's `share/`.

## Quick start

```bash
paddock build claude                # builds paddock-proxy, paddock-base and paddock-claude:<latest>
paddock create claude web ~/src/web --domains pypi.org,.githubusercontent.com
paddock attach web                  # starts if needed, runs claude in /workspace
```

Log in once with `/login` inside Claude Code; the login lives in the instance's
own home volume `pd-web-home` and survives `stop`/`start` and `recreate`
(but not `rm`).

## Commands

| Command | |
| --- | --- |
| `create <tool> <name> <path> [--domains d1,d2] [--no-agents-md]` | create (not started). The tool is fixed for the instance. Refuses `/`, `$HOME`, parents of `$HOME`, and the paddock config dir. Adds `AGENTS.md` to the workspace if missing (see [Agent instructions](#agent-instructions)) |
| `start <name>` / `stop <name>` | idempotent; proxy first, then agent |
| `attach <name> [--yolo] [-- tool args]` | runs the tool's command. `--yolo` adds the tool's `yolo_args` (for Claude Code `--dangerously-skip-permissions`) and prints a warning |
| `shell <name>` | bash in the agent as the unprivileged user |
| `rm <name> [--force]` | removes containers, networks, home volume and config. Never touches the workspace |
| `recreate <name>` | *(extra)* recreates containers, e.g. after `build` of a new version. Keeps the home volume (login). Adds `AGENTS.md` to the workspace if missing |
| `list` | name, state, tool, number of extra domains, workspace |
| `domains <name> list\|add\|rm\|edit` | live reload via `squid -k reconfigure`, no restarts |
| `logs <name> [-f] [-n N] [--raw]` | `TIME ALLOWED/DENIED METHOD host:port (squid-code status)` |
| `build <tool> [--version X]` | builds proxy, base and tool image. Without `--version`, the latest version of the tool's npm package is resolved and pinned |
| `tools` | available tools, their built version and where their definition comes from |

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

Shipped defaults live in the data directory (`share/` in the repository):

```
share/
  config                      default limits and relabel flag
  domains.txt                 domains every instance may reach (empty by default)
  Containerfile.proxy
  Containerfile.base          shared base of all agent images
  PADDOCK.md                  sandbox notes for the agent, built into the base image
  AGENTS.md                   default AGENTS.md written into workspaces
  tools/<tool>/
    tool.conf                 command, yolo_args, npm_package
    Containerfile             FROM paddock-base; installs the tool (build arg TOOL_VERSION)
    domains.txt               domains every instance of this tool may reach
    env                       environment set in the agent container (KEY=VALUE)
```

Your own files live in the config directory. A file there at the same relative
path as a data file replaces it, e.g. `~/.config/paddock/domains.txt` or
`~/.config/paddock/tools/claude/Containerfile`. `config` is the exception: its
keys are merged over the defaults, so it only needs the settings you change. A
new directory `~/.config/paddock/tools/<tool>/` with a `tool.conf` and a
`Containerfile` adds a tool.

```
~/.config/paddock/            (mode 0700, never mounted into the agent)
  config                      optional: settings that differ from share/config
  images                      written by `paddock build`: built version per tool
  build/                      optional extra build-context files (e.g. a corporate CA)
  squid-extra.conf            optional, included at the end of every squid.conf (e.g. cache_peer)
  ...                         optional overrides of data files (see above)
  instances/<name>/
    tool                      the instance's tool
    workspace                 absolute host path
    domains.txt               per-instance extra domains
    proxy/                    generated: squid.conf + allowlist.txt (mounted read-only into the proxy)
```

An instance's allowlist is `domains.txt` + `tools/<tool>/domains.txt` +
`instances/<name>/domains.txt`; `paddock domains <name> list` shows each entry's
source.

`config` settings (empty value disables a limit): `agent_memory=4g`,
`agent_cpus=2`, `agent_pids_limit=2048`, `proxy_memory=256m`, `proxy_cpus=0.5`,
`proxy_pids_limit=256`, `relabel=` (`z`/`Z` on SELinux hosts), `agents_md=yes`
(`no`: never add `AGENTS.md` to workspaces). Limit and `env` changes take effect
on `paddock recreate <name>`.

### Agent instructions

The base image contains `/etc/paddock/PADDOCK.md`. It tells the agent what the
sandbox looks like, and that it cannot widen it itself: when the proxy blocks a
domain or it needs a system package, it should stop and ask you, giving the
exact `paddock domains <instance> add ...` command or the Containerfile change.
The instance name comes from `$PADDOCK_INSTANCE`.

So that agents read it, `create` and `recreate` write a short `AGENTS.md` into
the workspace that points to that file. Claude Code and other agents read
`AGENTS.md` automatically. paddock never overwrites an existing `AGENTS.md`;
if your project already has one, add a reference to `/etc/paddock/PADDOCK.md`
yourself if you want it. Skip it per instance with `create --no-agents-md` or
for all instances with `agents_md=no` in `config`.

Both files can be overridden in the config dir (`PADDOCK.md`, `AGENTS.md`). A
changed `PADDOCK.md` takes effect after `paddock build <tool>` and
`paddock recreate <name>`; if you override `Containerfile.base`, keep its
`COPY PADDOCK.md` line.

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
