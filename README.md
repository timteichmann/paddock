# paddock

Isolated coding-agent instances on rootless Podman. Supported tools: Claude Code
(`claude`) and the Codex CLI with a local model (`codex-local`, see
[Local models](#local-models)); more can be added as tool definitions. Each
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
- `paddock-llm:<tag>-<backend>`: only for [local models](#local-models):
  llama.cpp's `llama-server`, compiled from source at a release tag for the
  CPU, Vulkan, CUDA or ROCm.

Claude Code runs with `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (no telemetry, error reporting
or update checks), so only the allowlisted API and login hosts are contacted.
Arch is rolling, so a rebuild picks up current packages.

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

With a local model instead (see [Local models](#local-models)):

```bash
paddock llm pull unsloth/Inkling-2-Mini-GGUF Mainline_Support/Inkling-2-Mini-UD-Q4_K_XL.gguf_file
echo 'llm_model=Inkling-2-Mini-UD-Q4_K_XL.gguf' >> ~/.config/paddock/config
echo 'llm_backend=vulkan' >> ~/.config/paddock/config   # or cpu, cuda, rocm
paddock build llm                   # compiles llama-server; paddock-llm:<tag>-vulkan
paddock build codex-local           # paddock-codex-local:<latest Codex>
paddock create codex-local api ~/src/api
paddock attach api                  # starts paddock-llm if needed, runs codex
```

## Commands

| Command | |
| --- | --- |
| `create <tool> <name> <path> [--domains d1,d2] [--packages p1,p2] [--no-agents-md]` | create (not started). The tool is fixed for the instance. Refuses some paths, see [Workspace paths](#workspace-paths). Adds `AGENTS.md` to the workspace if missing (see [Agent instructions](#agent-instructions)) |
| `start <name>` / `stop <name>` | idempotent; proxy first, then agent |
| `attach <name> [--yolo] [-- tool args]` | runs the tool's command. `--yolo` adds the tool's `yolo_args` (for Claude Code `--dangerously-skip-permissions`) and prints a warning |
| `shell <name>` | bash in the agent as the unprivileged user |
| `rm <name> [--force]` | removes containers, networks, home volume and config. Never touches the workspace |
| `recreate <name>` | *(extra)* recreates containers, e.g. after `build` of a new version. Keeps the home volume (login). Adds `AGENTS.md` to the workspace if missing |
| `list` | name, state, tool, number of extra domains and packages, workspace |
| `domains <name> list\|add\|rm\|edit` | live reload via `squid -k reconfigure`, no restarts |
| `packages <name> list\|add\|rm\|edit` | extra pacman packages for this instance, see [Per-instance packages](#per-instance-packages). Takes effect on `recreate` |
| `logs <name> [-f] [-n N] [--raw]` | `TIME ALLOWED/DENIED METHOD host:port (squid-code status)` |
| `build <tool> [--version X]` | builds proxy, base and tool image. Without `--version`, the latest version of the tool's npm package is resolved and pinned |
| `build llm [--version bNNNNN]` | builds the model server image for `llm_backend` from a llama.cpp release tag (default: the latest release) |
| `llm start\|stop\|restart\|status` | the shared model server, see [Local models](#local-models). `start` happens automatically on `start`/`attach` of a local-model instance; `restart` applies changed `llm_*` settings, a new image or model |
| `llm logs [-f] [-n N]` | the model server's log |
| `llm pull <hf-repo> <file>` | downloads a GGUF file from Hugging Face into the models dir (resumable; sends `$HF_TOKEN` if set) |
| `tools` | available tools, their built version and where their definition comes from |
| `purge [--force] [--keep-images]` | removes everything paddock created for your user: all instances (containers, networks, home volumes incl. logins, also ones whose config is gone), the model server, the `localhost/paddock-*` images, the downloaded models in the default models dir and the config dir (`--keep-images` keeps the proxy, base, tool and model server images and the models; instance images go with their instance; a configured `llm_models_dir` is never removed). Lists it all and asks first. Never touches workspaces. Run it before uninstalling |
| `doctor` | checks the host (Podman version, rootless, netavark, subuid/subgid, cgroup delegation, SELinux relabel, GPU access for `llm_backend`) and prints distro-specific fixes. Exits non-zero if something required is missing |

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
  llm/Containerfile           model server image (build args LLAMA_VERSION, BACKEND)
  tools/<tool>/
    tool.conf                 command, yolo_args, npm_package; optional service,
                              config_template, config_path (see below)
    Containerfile             FROM paddock-base; installs the tool (build arg TOOL_VERSION)
    domains.txt               domains every instance of this tool may reach
    env                       environment set in the agent container (KEY=VALUE)
    <config_template>         optional, e.g. codex-local/config.toml
```

Optional `tool.conf` keys: `service=llm` makes the tool's instances use the
shared [model server](#local-models). `config_template=<file>` and
`config_path=/etc/<dir>/<file>` render `<file>` from the tool directory for
each instance on every start (placeholders `@LLM_HOST@`, `@LLM_PORT@`,
`@LLM_MODEL@`, `@LLM_CTX@`, `@LLM_COMPACT@`, 80% of the context) and mount it
read-only at `config_path`; its directory is mounted, so it must be one of its
own.

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
    tool-config/              generated from config_template (mounted read-only into the agent)
~/.cache/paddock/models/      downloaded models (llm_models_dir)
```

An instance's allowlist is `domains.txt` + `tools/<tool>/domains.txt` +
`instances/<name>/domains.txt`; `paddock domains <name> list` shows each entry's
source.

`config` settings (empty value disables a limit): `agent_memory=4g`,
`agent_cpus=2`, `agent_pids_limit=2048`, `proxy_memory=256m`, `proxy_cpus=0.5`,
`proxy_pids_limit=256`, `relabel=` (`z`/`Z` on SELinux hosts), `agents_md=yes`
(`no`: never add `AGENTS.md` to workspaces), and the `llm_*` settings of the
[model server](#local-models). Limit and `env` changes take effect
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

### Local models

Tools with `service=llm`, such as `codex-local`, run on a model on your own
hardware instead of a cloud API. One model server serves all of them:

```
 pd-a-int (codex-local)                pd-b-int (codex-local)       pd-c-int (claude)
 ┌───────────┐  ┌────────────┐          ┌───────────┐  ┌──────────┐  ┌───────────┐ ┌──────────┐
 │ pd-a-agent│  │ pd-a-proxy │          │ pd-b-agent│  │pd-b-proxy│  │ pd-c-agent│ │pd-c-proxy│
 └─────┬─────┘  └────────────┘          └─────┬─────┘  └──────────┘  └───────────┘ └──────────┘
       │ http://paddock-llm:8080 (direct)     │                       no path to paddock-llm
       └──────────────┐     ┌─────────────────┘
               ┌──────┴─────┴─────┐  paddock-llm-net (internal, nothing else on it)
               │   paddock-llm    │  llama-server, no route out,
               │   GPU devices    │  model file read-only
               └──────────────────┘
```

- **One container, `paddock-llm`,** runs `llama-server` with the model file
  mounted read-only. It sits on its own internal network and joins the
  internal network of each local-model instance at a fixed address (the
  second-to-last of the subnet; the proxy has the last). It never joins the
  network of any other instance, so Claude Code instances have no path to it.
  It has no route out and no proxy access: each proxy denies its address.
- **Agents reach it directly** as `paddock-llm:8080` (an `/etc/hosts` entry and
  `NO_PROXY`), not through their proxy. The `codex-local` tool needs no
  domains at all.
- **Started on demand:** `start` and `attach` of a local-model instance start
  it if needed and wait until the model is loaded. `paddock llm stop` stops
  it; it is not stopped with the instances. If you change `llm_*` settings, the
  image or the model file, it is recreated on its next start, or now with
  `paddock llm restart` (which interrupts running local-model sessions).
- **API only:** `--no-webui` and `--no-slots` (the slots endpoint shows other
  clients' prompts); llama-server's built-in tools, MCP and `/props` writes stay
  off. Rootless, `--cap-drop=ALL`, `no-new-privileges`, read-only root
  filesystem, `llm_*` resource limits.

Setup:

1. Pick the backend in `~/.config/paddock/config`: `llm_backend=cpu`,
   `vulkan` (AMD and Intel GPUs, Mesa drivers in the image), `cuda` (NVIDIA;
   needs nvidia-container-toolkit and a CDI spec,
   `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`) or `rocm`
   (AMD). `paddock doctor` checks GPU access. The GPU is passed through with
   `--device` and `--group-add keep-groups` (`llm_devices=auto`; keep-groups
   needs the crun runtime, Podman's default on current distributions); set
   `llm_devices` to choose devices yourself.
2. `paddock build llm` compiles `llama-server` for that backend at the latest
   llama.cpp release (or `--version bNNNNN`). Inkling 2 Mini needs **b12611 or
   later**: earlier releases produce gibberish with it.
3. `paddock llm pull <hf-repo> <file>` downloads a GGUF file into
   `~/.cache/paddock/models` (`llm_models_dir`); set `llm_model=<file>.gguf`.
4. `paddock build codex-local`, then create instances with
   `paddock create codex-local <name> <path>`.

Settings (`llm_*` in `config`):

| Setting | Default | |
| --- | --- | --- |
| `llm_backend` | `cpu` | `cpu`, `vulkan`, `cuda` or `rocm`; takes effect on `paddock build llm` |
| `llm_model` | | GGUF file name in the models dir |
| `llm_models_dir` | `~/.cache/paddock/models` | absolute path |
| `llm_ctx` | `65536` | context size in tokens, shared by all requests of all instances. Codex compacts its history at 80% of it |
| `llm_args` | Inkling 2 Mini sampling | extra `llama-server` arguments, split on whitespace (no quoting) |
| `llm_devices` | `auto` | `auto` (by backend), empty, or podman `--device` values separated by commas |
| `llm_memory`, `llm_cpus`, `llm_pids_limit` | `""`, `""`, `1024` | resource limits |

#### Inkling 2 Mini

[Inkling 2 Mini](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF) is a
26B mixture-of-experts model with 3.4B active parameters (its middle layers run
three times, so compute per token is closer to 5.4B), Apache 2.0, made for
agentic and coding use. For llama.cpp use the files in `Mainline_Support/`
(the repository root holds a layout only Unsloth's own builds read); `pull`
renames their `.gguf_file` suffix to `.gguf`. The quant should fit your GPU
memory together with the context:

| Quant | Size |
| --- | --- |
| `UD-Q3_K_XL` | 13.6 GB |
| `UD-IQ4_XS` | 15.7 GB |
| `UD-Q4_K_XL` | 17.6 GB (recommended where it fits) |
| `UD-Q8_K_XL` | 22.9 GB |

The model card recommends temperature 1.0 without truncation (top-p 1.0,
top-k off, min-p 0), the default `llm_args`. It also warns that the model can
get stuck in long reasoning loops, may delete or overwrite files without
asking, and may misreport its results: keep Codex's approvals on (no `--yolo`)
and review its changes.

#### codex-local

`codex-local` is OpenAI's Codex CLI (npm package `@openai/codex`) configured
for the model server through `/etc/codex/config.toml`, its system config:
provider `paddock-llm` with the Responses API (`llama-server` serves
`/v1/responses`), the model's context window, no web search, update checks,
analytics or feedback uploads. Codex's own sandbox is off
(`sandbox_mode = "danger-full-access"`), since paddock is the sandbox;
approvals stay on (`approval_policy = "on-request"`), and `attach --yolo` turns
them off. No OpenAI account or login is needed. To change a setting for one
instance, put it in `~/.codex/config.toml` inside the instance; for all
instances, override `tools/codex-local/config.toml` in the config dir.

### Agent instructions

The base image contains `/etc/paddock/PADDOCK.md`. It tells the agent what the
sandbox looks like, and that it cannot widen it itself: when the proxy blocks a
domain or it needs a system package, it should stop and ask you, giving the
exact `paddock domains <instance> add ...` or `paddock packages <instance> add ...`
command.
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
- Repositories in subdirectories of the workspace are not protected.

## How isolation works

- **Filesystem:** only the workspace is bind-mounted (`/workspace`), with
  `.git/config` and `.git/hooks` read-only (see [Git](#git)). Home is a
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
- **Model server:** see [Local models](#local-models). It joins only the
  internal networks of local-model instances, has no route out, and each proxy
  denies its address. It does not route between the networks it is on: paddock
  turns IP forwarding off in its network namespace, and without capabilities
  it cannot turn it on (agents cannot add routes through it either).
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
The local-model checks (instances `t4`/`t5`: model server reachable from
local-model instances only, no route out, no proxy use, survives instance
removal) run when `paddock build llm`, `llm_model` with its file and
`paddock build codex-local` are in place; `PD_TEST_LLM=0` skips them. They send
one short request to the model.

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
- **Shared model server:** all local-model instances share `paddock-llm`. An
  agent that exploits a bug in `llama-server` could read the other
  local-model instances' prompts (their code) and alter the model's answers to
  them, i.e. steer those agents and, through their workspaces, what you later
  run on the host. Instances of other tools are not affected (no path to it).
  Requests also queue behind each other, and one instance can slow down the
  rest. Do not mix trusted and untrusted projects among local-model instances.
- **GPU passthrough** gives the model server access to the GPU driver, a large
  kernel interface. A container escape through it needs a `llama-server` bug
  first; `llm_backend=cpu` avoids it.

## License

Copyright (C) 2026 Tim Teichmann

paddock is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.

SPDX-License-Identifier: GPL-2.0-or-later
