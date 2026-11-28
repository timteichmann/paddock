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

Any Linux distribution with:

- rootless Podman ≥ 4.4 using the netavark network backend; install it with
  your distribution's package manager, see Podman's
  [installation guide](https://podman.io/docs/installation)
- `newuidmap`/`newgidmap` and subuid/subgid entries for your user
- bash ≥ 4.4 and curl
- for the resource limits: cgroup v2 with the memory, cpu and pids controllers
  delegated to your user (the systemd default on current distributions)

On SELinux-enforcing hosts (e.g. Fedora), set `relabel=Z` in
`~/.config/paddock/config`. No root and no sudo at runtime.
On Arch Linux, the [package](#arch-linux-package) pulls in everything.

`paddock doctor` checks all of this and says what is missing and how to fix it.

## Images

All images are built from `archlinux:latest`, whatever distro the host runs:

- `paddock-proxy`: Squid only.
- `paddock-base`: bash, git, ripgrep, curl, python and nodejs/npm. No sudo is
  installed, and setuid bits are stripped.
- `paddock-<tool>:<version>`: `FROM paddock-base`, plus the tool at a pinned
  version (`paddock build <tool> --version X`; without `--version`, the latest
  version of the tool's npm package is resolved and pinned).
- `paddock-inst:<name>`: only for instances with
  [extra packages](#per-instance-packages): the tool image plus those packages.

Claude Code runs with `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reporting
or update checks), so only the allowlisted API and login hosts are contacted.
Arch is rolling, but podman reuses cached layers until the `archlinux:latest`
image itself changes; `paddock build <tool> --refresh` rebuilds every layer
with current packages. Run `paddock recreate <name>` afterwards.

## Install

paddock is the `paddock` script plus its data directory `share/` (defaults and
tool definitions). From a checkout:

```bash
./install.sh                       # as a user: ~/.local/bin/paddock + ~/.local/share/paddock
sudo ./install.sh                  # system-wide: /usr/local
./install.sh --prefix /opt/paddock # any prefix: <prefix>/bin, <prefix>/share/paddock
```

`install.sh` only copies files; it never installs packages or touches your
config. As a user it runs `paddock doctor` at the end. Running it again
updates the installation, and `./install.sh --uninstall [--prefix DIR]`
removes it. Your config, instances and Podman images are kept. To remove those
as well, run `./install.sh --uninstall --purge`, which runs `paddock purge` first.
For distro packages,
`DESTDIR=$pkgdir ./install.sh --prefix /usr` stages the files.

It also installs bash completion (commands, options, instance and tool names,
and allowlisted domains for `domains <name> rm`) to
`<prefix>/share/bash-completion/completions/paddock`, which the
`bash-completion` package loads automatically. Without an install, run
`source completions/paddock.bash`.

### Arch Linux package

`packaging/arch/PKGBUILD` packages the checkout it sits in. It downloads
nothing and needs no release tag, and it pulls in Podman, netavark and curl:

```bash
git clone https://github.com/timteichmann/paddock && cd paddock/packaging/arch
makepkg -si
```

To upgrade, run `git pull` and `makepkg -si` again. The version is the script
version plus the commit, e.g. `0.1.0.r3.gbaed21f`, so each pulled commit is an
upgrade for pacman. Uncommitted changes in the checkout are packaged too.

`sudo pacman -R paddock` removes the package. pacman never touches home
directories, so your instances, images and `~/.config/paddock` stay. To remove them,
run `paddock purge` as your user first. pacman reminds you on install, and
after removal it prints the manual clean-up commands.

paddock looks for the data directory in `$PADDOCK_DATA_DIR`, then `share/` next
to the (symlink-resolved) script, then `<prefix>/share/paddock` for a script in
`<prefix>/bin`, then `~/.local/share/paddock`, `/usr/local/share/paddock` and
`/usr/share/paddock`. Running `./paddock` from a checkout uses the checkout's
`share/`.

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
| `create <tool> <name> <path> [--domains d1,d2] [--packages p1,p2]` | create (not started). The tool is fixed for the instance. Refuses some paths, see [Workspace paths](#workspace-paths) |
| `start <name>` / `stop <name>` | idempotent; proxy first, then agent |
| `attach <name> [--yolo] [-- tool args]` | runs the tool's command. `--yolo` adds the tool's `yolo_args` (for Claude Code `--dangerously-skip-permissions`) and prints a warning |
| `shell <name>` | bash in the agent as the unprivileged user |
| `rm <name> [--force]` | removes containers, networks, home volume and config. Never touches the workspace |
| `recreate <name>` | *(extra)* recreates containers, e.g. after `build` of a new version. Keeps the home volume (login) |
| `list` | name, state, tool, number of extra domains and packages, workspace |
| `domains <name> list\|add\|rm\|edit` | live reload via `squid -k reconfigure`, no restarts |
| `packages <name> list\|add\|rm\|edit` | extra pacman packages for this instance, see [Per-instance packages](#per-instance-packages). Takes effect on `recreate` |
| `logs <name> [-f] [-n N] [--raw]` | `TIME ALLOWED/DENIED METHOD host:port (squid-code status)` |
| `build <tool> [--version X] [--refresh]` | builds proxy, base and tool image. Without `--version`, the latest version of the tool's npm package is resolved and pinned. `--refresh` rebuilds without the layer cache, to pick up current Arch packages |
| `tools` | available tools, their built version and where their definition comes from |
| `purge [--force] [--keep-images]` | removes everything paddock created for your user: all instances (containers, networks, home volumes incl. logins, also ones whose config is gone), the `localhost/paddock-*` images and the config dir (`--keep-images` keeps the proxy, base and tool images; instance images go with their instance). Lists it all and asks first. Never touches workspaces. Run it before uninstalling |
| `doctor` | checks the host (Podman version, rootless, netavark, subuid/subgid, cgroup delegation, SELinux relabel) and prints distro-specific fixes. Exits non-zero if something required is missing |

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
  tools/<tool>/
    tool.conf                 command, yolo_args, npm_package, protect_paths
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
    packages.txt              per-instance extra pacman packages (see below)
    proxy/                    generated: squid.conf + allowlist.txt (mounted read-only into the proxy)
```

An instance's allowlist is `domains.txt` + `tools/<tool>/domains.txt` +
`instances/<name>/domains.txt`; `paddock domains <name> list` shows each entry's
source.

`config` settings (empty value disables a limit): `agent_memory=4g`,
`agent_cpus=2`, `agent_pids_limit=2048`, `proxy_memory=256m`, `proxy_cpus=0.5`,
`proxy_pids_limit=256`, `relabel=` (`z`/`Z` on SELinux hosts). Limit and `env` changes take effect
on `paddock recreate <name>`.

### Per-instance packages

Packages that only one project needs (e.g. `godot` for a game) do not have to
go into the shared Containerfiles. Like `domains.txt`, each instance has its own
`packages.txt`:

```bash
paddock create claude game ~/src/game --packages godot
paddock packages game add blender      # builds localhost/paddock-inst:game
paddock recreate game                  # switches the instance to it
paddock packages game list|rm|edit
```

- For an instance with packages, paddock builds `localhost/paddock-inst:<name>`
  `FROM` the instance's tool image with
  `pacman -Syu --noconfirm --needed <packages>` (a full upgrade, because Arch
  does not support partial upgrades) and strips setuid bits again. Instances
  without packages use the tool image directly.
- The build runs on the host like `paddock build`, not through the instance's
  proxy, so the Arch mirrors do not need to be allowlisted. The agent cannot
  change the list; only you can.
- `add`, `rm` and `edit` build the new image first and save the list only if
  the build succeeds, so an unknown package changes nothing. The running
  containers keep their image until `paddock recreate <name>`; `start` and
  `attach` warn while the list and the containers differ.
- `recreate` rebuilds the image when it is out of date, e.g. after
  `paddock build <tool>` produced a new tool image. Without packages it
  removes the instance image. `rm` removes it as well.
- Names are official Arch repository packages or groups (`[A-Za-z0-9@._+-]`, not
  starting with `-` or `.`). For AUR packages or anything else, override the
  tool's Containerfile (see [Files](#files)); that applies to all instances of
  the tool.

### Agent instructions

The base image contains `/etc/paddock/PADDOCK.md`. It tells the agent what the
sandbox looks like, and that it cannot widen it itself: when the proxy blocks a
domain or it needs a system package, it should stop and ask you, giving the
exact `paddock domains <instance> add ...` or `paddock packages <instance> add ...`
command.
The instance name comes from `$PADDOCK_INSTANCE`.

So that the agent reads it in every session, each tool's image also has it
where the tool looks for global instructions; for Claude Code that is
`/etc/claude-code/CLAUDE.md`, its managed instructions file. It is read in
addition to the project's own `CLAUDE.md`/`AGENTS.md`, owned by root and so
read-only for the agent, and nothing is written into your workspace.

`PADDOCK.md` can be overridden in the config dir. A changed `PADDOCK.md` takes
effect after `paddock build <tool>` and `paddock recreate <name>`; if you
override `Containerfile.base` or a tool's `Containerfile`, keep their
`COPY PADDOCK.md` lines.

Earlier versions wrote an `AGENTS.md` pointing to `/etc/paddock/PADDOCK.md`
into workspaces. paddock leaves such files alone; delete them if you no
longer want them. `create --no-agents-md` and the `agents_md` setting are
ignored with a warning.

### Workspace paths

`create` refuses a workspace that is, contains or is inside:

- `/`, `$HOME` or a parent of `$HOME`
- a hidden directory of `$HOME` (`~/.config`, `~/.local`, `~/.ssh`, ...)
- the paddock config dir, the data dir or the directory of the `paddock`
  script (e.g. a checkout you run `./paddock` from)
- `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, `$XDG_RUNTIME_DIR` and Podman's storage
- another instance's workspace (two instances may share the same workspace)

The workspace is checked again before its containers are created or started:
if it now resolves to a different path, e.g. because a directory in the path
was replaced by a symlink, paddock refuses to start. Filesystems mounted below
the workspace are not visible in the instance.

### Git

The workspace is a bind mount of a host directory, so do all remote git work
(fetch, pull, push, PRs) on the host. Instances get no git credentials and need
no access to GitHub or other forges; `git` in the image is for local commits,
diffs and history in `/workspace`.

git on the host runs commands configured in `.git/config` (e.g.
`core.fsmonitor`, `core.pager`, diff and filter drivers) and `.git/hooks`. So
that the agent cannot set these, paddock mounts `.git/config` and `.git/hooks`
read-only in the instance if the workspace has a `.git` directory when the
containers are created. The agent can still commit, branch, merge and rebase;
commands that write `.git/config` (`git config`, `git remote add`, setting an
upstream) fail inside the instance. A `.git` file (worktree, submodule) is
mounted read-only as a whole.

- If the repository is created after the instance (`git init` or `git clone`
  inside it), run `paddock recreate <name>`; `start` and `stop` remind you.
- `.git/commondir` makes git read config and hooks from another directory.
  paddock cannot prevent the agent from creating it, so `start` and `stop`
  warn when it exists.
- Changes you make to `.git/config` on the host (e.g. `git remote add`) are
  visible in the instance after `paddock recreate <name>`.
- With `extensions.worktreeConfig` set, `.git/config.worktree` is mounted
  read-only as well (created empty if missing).

**Nested repositories are not protected.** The agent can create a repository
in a subdirectory (or change a submodule's `.git` file or `.git/modules/*`)
and set its `core.fsmonitor` or hooks. If the workspace's index lists it as a
submodule, which the agent can also arrange, `git status`, `git diff` or
`git add` in the workspace on the host runs git in it with that config. The
same applies to linked worktrees (`.git/worktrees/*`). paddock cannot prevent
this without taking `.git` away from the agent, so `start` and `stop` warn
when the workspace has nested repositories, submodule repositories in
`.git/modules`, or a linked worktree whose `commondir` points elsewhere.
When you see such a warning:

- remove nested repositories you did not create yourself, and check the
  config and hooks of the others (`<dir>/.git/config`, `<dir>/.git/hooks`)
  before running git in the workspace;
- `git -c diff.ignoreSubmodules=all status` and `... diff` do not run git in
  submodules; `git add` still does.

### Tool settings in the workspace

Coding agents read settings from the project, and some of them run commands:
Claude Code runs hooks from `.claude/settings.json` and
`.claude/settings.local.json`, and MCP servers from `.mcp.json`. If you also run
the tool on the host in the same directory, settings the agent wrote there
would run with your full permissions. So paddock mounts the tool's
`protect_paths` (from its `tool.conf`) read-only in the instance; for Claude
Code `.claude/` and `.mcp.json`.

- A directory entry (trailing `/`, e.g. `.claude/`) is created in the
  workspace if it is missing, so it is protected from the start. A file entry
  (e.g. `.mcp.json`) is only protected if it exists when the containers are
  created; if it appears later, `start` and `stop` warn until you check it and
  run `paddock recreate <name>`.
- The agent in the instance cannot change these settings either. Claude Code
  there stores permission rules you allow with "don't ask again" in
  `~/.claude/settings.json` in the instance's home volume. To change the
  project's settings, edit them on the host and run `paddock recreate <name>`.
- Entries are single names directly in the workspace. Instructions such as
  `CLAUDE.md` stay writable: they cannot run commands, but review changes to
  them like any other file.

## How isolation works

- **Filesystem:** only the workspace is bind-mounted (`/workspace`), with
  `.git/config` and `.git/hooks` read-only (see [Git](#git)), and the tool's
  project settings read-only (see
  [Tool settings in the workspace](#tool-settings-in-the-workspace)). Home is a
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
shellcheck paddock install.sh completions/paddock.bash tests/*.sh
tests/distro.sh              # install tests in fresh ubuntu and arch containers
tests/distro.sh arch-pkg     # build, namcap, install and remove the Arch package
tests/acceptance.sh          # full suite on this host, after `paddock build claude`
```

`tests/distro.sh [ubuntu] [debian] [arch] [fedora]` runs `tests/install-test.sh`
in a fresh container per distro (podman or docker). It installs the host
packages, checks the `paddock doctor` hints before and after, and runs
`install.sh` with a user, system, custom and `DESTDIR` prefix, a reinstall and an
uninstall. It does not start instances, because that would need nested
rootless Podman. Behind a proxy, pass
`PD_ENGINE_ARGS=--network=host` and `PD_TEST_CA=/path/ca.crt` (HTTP(S)_PROXY are
passed through). `arch-pkg` copies the checkout, runs `makepkg` in
`packaging/arch`, and installs, upgrades (after a test commit) and removes the package.

`tests/acceptance.sh` creates `t1`/`t2` (workspaces `/tmp/pd-t1`, `/tmp/pd-t2`), runs spec tests 1–11
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
- The agent can change any file in the workspace. Review its changes before
  you run them on the host: build files, scripts, tests, `.envrc`, editor
  settings and the like run with your full permissions there.
- Kernel and Podman escapes are out of scope; use a VM for untrusted code.

## License

Copyright (C) 2026 Tim Teichmann

paddock is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.

SPDX-License-Identifier: GPL-2.0-or-later
