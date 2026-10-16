<p align="center"><a href="https://github.com/jordanhillis/nebula-manager/"><img src="resources/img/banner-web.png" alt="Nebula Manager"></a></p>

<p align="center">
  <a href="/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green.svg"></a>
  <a href="https://www.gnu.org/software/bash/"><img alt="Shell: Bash" src="https://img.shields.io/badge/language-bash-blue.svg"></a>
  <a href="https://kernel.org/"><img alt="Platform: Linux" src="https://img.shields.io/badge/platform-Linux-informational?style=flat-square"></a>
  <a href="https://github.com/slackhq/nebula"><img alt="Nebula" src="https://img.shields.io/badge/nebula-supported-brightgreen"></a>
  <a href="https://github.com/jordanhillis/nebula-manager/commits"><img alt="Last Commit" src="https://img.shields.io/github/last-commit/jordanhillis/nebula-manager"></a>
  <a href="https://github.com/jordanhillis/nebula-manager/releases"><img alt="Latest Release" src="https://img.shields.io/github/releases/jordanhillis/nebula-manager?sort=semver&display_name=tag&style=flat-square"></a>
</p>

>A fast, interactive CLI tool to **install, configure, and operate** [Slack Nebula](https://github.com/slackhq/nebula) — wrapping certs, firewall policy, service control, connectivity checks, and scheduled updates into one easy-to-use tool.

> **v2 runs as a normal user.** The old "must be root" model is gone: the tool
> runs least-privilege and calls `sudo` only for the specific actions that need
> it (writing `/etc/nebula`, controlling systemd units, touching kernel/firewall
> state). Certificate work, benchmarks and diagnostics never need root.

---

## ⚙️ Features

- 🔓 **Least-privilege by default** – runs as your user; granular `sudo` on demand.
- 🚀 **Install & Update Nebula** from official releases (arch/OS aware).
- 🛡 **Certificate management** – list, generate, view, bundle, check expiry, and **revoke with reasons**.
- 🗝️ **Configurable certificate workspaces** – keep PKI in a user-owned store, switch at runtime, auto-detect existing stores.
- 📝 **Configuration management** – interactively edit `config.yml` with validation to prevent bad deploys.
- 🔥 **Firewall management** – control inbound/outbound rules, defaults, and conntrack settings.
- 📡 **Connectivity tools** – multi-node reachability & latency table.
- 🏁 **Benchmarks** – `iperf3` server/client modes with custom overlay IPs (unprivileged).
- 🩺 **Diagnostics** – one-shot view of TUN IP, listening UDP socket, and certificate expiry.
- 🔌 **Listen-port aware** – reads `listen.port`, auto-detects OS-assigned ports (`port: 0`), and honors a configurable `default_port`.
- 🖥 **whiptail-first UI** – curses menus via `whiptail`; `dialog` is used only as a last resort, with a plain-text fallback for headless runs.
- 📋 **Service orchestration** – manage all enabled servers, with per-server status.
- ⏪ **Update Nebula with rollback** if download or config validation fails.
- ⏰ **Auto-update scheduler** – via cron (`nebula-manager --auto-update-nebula`).
- 🆕 **First-run setup** – if no config is found, prompts to **create (offline template)**, **browse**, or **download**.
- 🖥 **Interactive TUI _and_ headless subcommands** – script it your way.

---

## 🏗️ Architecture

The tool is a thin entrypoint plus four modules under `lib/`:

```
nebula-manager          # entrypoint: arg parsing, dispatch, TUI root
lib/
  ui.sh                 # colours, status badges, whiptail/dialog + plain menus
  pki.sh                # CA, signing, inspection, workspaces, client bundling
  bench.sh              # iperf3 server/client, connectivity, diagnostics
  system.sh             # elevate()/sudo, systemd, /etc/nebula, install/update
  nebula-manager.conf.template  # bundled config template (offline first-run)
tests/                  # standalone mock-driven Bash test harness
run_tests.sh            # test runner (also: make test)
```

`nebula-manager.sh` is kept as a thin **backwards-compatibility shim** that
re-execs the real entrypoint.

### Privilege model

- `elevate() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }` — the single choke point for privilege escalation.
- `path_requires_root()` classifies a target path; `ensure_dir()` elevates **only** when the nearest existing parent isn't writable by you.
- Everything else (printing/signing certs, zipping bundles, pings, `iperf3`, `ss`) runs as you.

Privileged actions (the only ones that use `sudo`):
`mkdir/chmod/write under system paths`, `mkdir -p /etc/nebula` + template download, systemd (`daemon-reload`, `enable`, `start/stop/restart/reload`), installing binaries into `bin_path`, and the self-update copy.

---

## 📥 Installation

> **Note (v2):** the implementation is now `nebula-manager` **plus the `lib/`
> directory**. Both are required — a lone single-file download won't work.

### 🔹 Option 1: Git clone (recommended)

```bash
git clone https://github.com/jordanhillis/nebula-manager.git
cd nebula-manager
./nebula-manager            # no sudo needed
```

### 🔹 Option 2: Download the entrypoint and modules

```bash
mkdir -p nebula-manager/lib && cd nebula-manager
base=https://raw.githubusercontent.com/jordanhillis/nebula-manager/refs/heads/main
curl -fsSL "$base/nebula-manager" -o nebula-manager
for m in ui.sh pki.sh bench.sh system.sh nebula-manager.conf.template; do
  curl -fsSL "$base/lib/$m" -o "lib/$m"
done
chmod +x nebula-manager
./nebula-manager
```

### 🔹 Install system-wide (optional, needs sudo once)

Use **Maintenance ▸ Install Script to System** inside the TUI, or copy manually:

```bash
sudo install -d /usr/local/bin /usr/local/lib/nebula-manager/lib
sudo install -m755 nebula-manager /usr/local/bin/nebula-manager
sudo cp lib/*.sh lib/*.template /usr/local/lib/nebula-manager/lib/
```

The entrypoint auto-discovers `lib/` in the following order:
`$NEBULA_MANAGER_LIB` → `<dir of entrypoint>/lib` → `/usr/local/lib/nebula-manager/lib` → `/usr/lib/nebula-manager/lib`.

---

## 📦 Dependencies

Nebula Manager checks for required tools on first run and prints an install
command if any are missing (skippable via `ignore_dependency_check` in the conf).

**Required:** `curl`, `wget`, `tar`, `jq`, `yq`, `systemd` (`systemctl`), `iputils-ping`
**Optional:** `iperf3` (bandwidth tests), `whiptail` (**strongly preferred** for the TUI; `dialog` is a last resort), `zip` (client bundles; falls back to `tar.gz`)

### Install all dependencies

**<img src="https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white" alt="Debian" height="20"/> / <img src="https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu" height="20"/>**
```bash
sudo apt update
sudo apt install -y awk curl findutils grep jq sed sudo systemd tar wget yq coreutils iperf3 iputils-ping whiptail zip
```
**<img src="https://img.shields.io/badge/RHEL-EE0000?logo=redhat&logoColor=white" alt="RHEL" height="20"/> / <img src="https://img.shields.io/badge/CentOS-262577?logo=centos&logoColor=white" alt="CentOS" height="20"/> / <img src="https://img.shields.io/badge/Rocky%20Linux-10B981?logo=rockylinux&logoColor=white" alt="Rocky Linux" height="20"/> / <img src="https://img.shields.io/badge/AlmaLinux-3D348B?logo=almalinux&logoColor=white" alt="AlmaLinux" height="20"/>
```bash
sudo dnf install -y curl findutils grep jq sed sudo systemd tar wget yq coreutils iperf3 iputils newt zip
```
**<img src="https://img.shields.io/badge/Arch%20Linux-1793D1?logo=arch-linux&logoColor=white" alt="Arch Linux" height="20"/> / <img src="https://img.shields.io/badge/CachyOS-00A3E0?logo=arch-linux&logoColor=white" alt="CachyOS" height="20"/>
```bash
sudo pacman -S --needed gawk curl findutils grep jq sed sudo systemd tar wget yq coreutils iperf3 iputils libnewt zip
```
(`whiptail` is provided by `libnewt` on Arch family.)

Supported distributions are auto-detected from `/etc/os-release` (Debian/Ubuntu, RHEL
family, Arch/CachyOS). On an unrecognised distribution the tool still runs as long
as the required tools are present — it just can't suggest the install command.

---

## 🔐 Certificates & workspaces

All PKI lives in a **certificate workspace** (a directory containing
`ca.crt`, `ca.key`, `<name>.crt`, `<name>.key`). Workspaces are ordinary
directories — keep them user-owned and no privilege is ever needed.

### Resolution precedence

1. `--cert-dir <path>` (CLI flag — highest priority)
2. `NEBULA_KEYS_DIR` environment variable
3. The saved interactive selection (chosen from **Certificates ▸ Switch Certificate Workspace**)
4. The active server's legacy directory: `$NEBULA_DIR/$cert_folder`
5. Default fallback: `$HOME/.local/share/nebula-manager/keys`

Use **Certificates ▸ Switch Certificate Workspace** to point the tool at a
different store; the choice is persisted in
`$XDG_CONFIG_HOME/nebula-manager/certdir`.

### First run

If no workspace is determined yet (no `--cert-dir`, no `NEBULA_KEYS_DIR`, no saved
selection, and no populated server cert dir), the TUI offers to pick one:

```
[!] No certificate workspace selected yet.
      1. Use existing store: /home/you/keys/nebula
      2. Use default store: /home/you/.local/share/nebula-manager/keys
      3. Use server dir: /etc/nebula/certs
      4. Browse for a certificate directory...
      5. Skip for now (use default)
```

Existing stores (`~/keys/nebula`, the default, and the active server's `certs/`)
are auto-detected and offered. **Browse** opens a directory browser
(`whiptail --dselect`) or lets you type a path. Your pick is remembered.

---

## 🛠️ Usage

### Interactive (menu-driven)

```bash
./nebula-manager
```

Menus cover: Certificates (list/CA/sign/view/expiry/**bundle zip**/revoke/workspace),
Configuration (validate/edit/firewall), Connectivity, Benchmarks, and Maintenance
(service toggle, update, scheduler, install, remove).

### Headless subcommands

```bash
# Certificate authority + signing (unprivileged)
./nebula-manager ca --name my-ca --duration 999999h --cert-dir ~/keys/nebula
./nebula-manager sign --name host1 --ip 10.42.0.2/24 --groups servers \
                      --duration 720 --cert-dir ~/keys/nebula

# Config management (offline template lives in lib/)
./nebula-manager config path
./nebula-manager config init          # create ~/.config/nebula-manager/nebula-manager.conf
./nebula-manager config refresh       # pull the latest template from your repo

# Inspect / bundle
./nebula-manager cert list
./nebula-manager cert expiry 30                 # certs expiring within 30 days
./nebula-manager cert bundle host1 ./bundles

# Benchmarks & diagnostics (unprivileged)
./nebula-manager bench server --port 5201
./nebula-manager bench client 10.42.0.2 --time 15 --streams 4 --reverse
./nebula-manager diag                            # TUN IP, UDP socket, cert expiry

# Utilities
./nebula-manager paths                           # resolved config / key dirs + UI backend
./nebula-manager ui                              # which UI backend is active (whiptail/dialog/plain)
./nebula-manager auto-update                     # update Nebula to latest
./nebula-manager --version
```

### Global flags

| Flag | Description |
|---|---|
| `--config <path>` | Override `nebula-manager.conf` location |
| `--cert-dir <path>` | Certificate workspace (overrides everything) |
| `--ui auto\|plain\|whiptail\|dialog` | Force a UI backend |
| `--no-color` | Disable coloured output |

### Environment variables

| Variable | Purpose |
|---|---|
| `NEBULA_KEYS_DIR` | Certificate workspace (2nd precedence, after `--cert-dir`) |
| `NEBULA_MANAGER_LIB` | Override the `lib/` module directory |
| `NEBULA_MANAGER_CONF` | Path to `nebula-manager.conf` (alias for `--config`) |
| `NEBULA_MANAGER_REPO` | `owner/repo` used for update checks / templates (default: git `origin`) |
| `NEBULA_MANAGER_REF` | Git ref (branch) used for update checks (default `main`) |
| `NEBULA_MANAGER_DEFAULT_REPO` | Last-resort repo when neither env nor git `origin` is available (default `jordanhillis/nebula-manager`) |
| `NEBULA_UI` | UI backend: `auto` (whiptail → dialog → plain), `whiptail`, `dialog`, `plain` |
| `NEBULA_DEFAULT_PORT` | Fallback Nebula listen port for diagnostics (default `4242`) |

---

## 🧩 Configuration: `nebula-manager.conf`

Nebula Manager reads an **INI-style** config (with sections). The path is
resolved as `--config` / `$NEBULA_MANAGER_CONF` → an existing
`/etc/nebula/nebula-manager.conf` → `$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf`.

### First run

If no config is found, the tool does **not** silently download anything. It asks:

```
[!] No configuration found at: /home/you/.config/nebula-manager/nebula-manager.conf
    What would you like to do?
      1. Create one at ~/.config/nebula-manager/nebula-manager.conf (from the bundled template)
      2. Use an existing config file (browse)...
      3. Download the latest template from <repo>
      4. Cancel
```

- **Create** copies the bundled template that ships in `lib/`
  (`lib/nebula-manager.conf.template`) — **offline, no root**.
- **Browse** opens a file browser (a `whiptail` menu navigator, or dialog's
  native `--fselect`).
- **Download** fetches the newest template from your source repo on request only.

After **Create**/**Download** the tool offers to open the new file in `$EDITOR`,
and then continues (it does not exit).

### Managing the config headlessly

```bash
./nebula-manager config path                 # print the resolved config path
./nebula-manager config init [--force]       # create it from the bundled template
./nebula-manager config init --config /etc/nebula/nebula-manager.conf
./nebula-manager config edit                 # open it in $EDITOR
./nebula-manager config refresh              # download the latest template
```

You can always point at any file with `--config`:

```bash
./nebula-manager --config=/path/to/nebula-manager.conf
```

### File format

- Comments use `#` (inline comments supported).
- Sections use `[global]` and `[server.<name>]`.
- Keys are `key=value`.

#### `[global]` keys

| Key | Description | Default |
|---|---|---|
| `bin_path` | Directory containing `nebula`/`nebula-cert` and where the tool may install itself | `/usr/local/bin` |
| `cert_folder` | Relative folder under each server's Nebula dir to store certs | `certs` |
| `cert_dir` | Explicit certificate workspace (equivalent to `NEBULA_KEYS_DIR`) | *(unset)* |
| `default_port` | Nebula listen port used by diagnostics when `config.yml` has `port: 0` | `4242` |
| `use_color` | Enable colored output | `true` |
| `use_icons` | Enable UI icons/symbols | `true` |
| `disable_version_check` | Skip script version checks | `false` |
| `ignore_dependency_check` | Skip dependency verification | `false` |
| `ignore_nebula_update` | Don't prompt about Nebula updates | `false` |

#### `[server.<name>]` keys

| Key | Description |
|---|---|
| `dir` | Nebula working dir for this server (e.g., `/etc/nebula/my-edge`) |
| `service` | systemd unit for this server (e.g., `/etc/systemd/system/nebula@service`) |
| `enabled` | `true` to include this server in batch operations |

### Example

```ini
[global]
bin_path=/usr/local/bin
cert_folder=certs
use_color=true
use_icons=true
disable_version_check=false
ignore_dependency_check=false
ignore_nebula_update=false

[server.edge-1]
dir=/etc/nebula/edge-1
service=/etc/systemd/system/nebula-edge1.service
enabled=true

[server.lighthouse]
dir=/etc/nebula/lighthouse
service=/etc/systemd/system/nebula-lighthouse.service
enabled=true

[server.lab]
dir=/etc/nebula/lab
service=/etc/systemd/system/nebula-lab.service
enabled=false
```

---

## ➕ Adding & ➖ Removing Servers

Append a `[server.<name>]` section, then ensure the referenced **Nebula dir**
contains a valid `config.yml` (a template is downloaded if missing) and the
**systemd unit** exists. Set `enabled=false` to exclude a server from batch
operations, or delete its section to remove it entirely.

---

## 🧪 Testing

A lightweight, dependency-free test harness (no BATS required) lives in `tests/`.
It uses a **mocked `sudo`** that records every invocation, so least-privilege
behaviour is asserted directly.

```bash
./run_tests.sh        # or: make test
```

What it covers:

| Test | Verifies |
|---|---|
| `tests/test_pki_unprivileged.sh` | CA + cert signing + bundling work with **no root**, in a `mktemp -d` workspace |
| `tests/test_sudo_mock.sh` | `sudo` is invoked **only** for privileged target dirs; failure is surfaced |
| `tests/test_resolve_dir.sh` | `--cert-dir` > `NEBULA_KEYS_DIR` > saved selection > legacy dir > default |
| `tests/test_port.sh` | listen-port resolution: `listen.port` → auto-detect → `default_port` |
| `tests/test_distro.sh` | distro detection + Arch/CachyOS package mapping; unknown distro no longer hard-fails |
| `tests/test_workspace.sh` | certificate workspace selection + "already known" detection |
| `tests/test_conf.sh` | config path resolution: user-first, `--config`/env override, bundled template + `config init` offline |
| `tests/test_template_online.sh` | optional (needs `NEBULA_TEST_ONLINE=1`) freshness check of the bundled template vs the repo |
| `tests/test_update.sh` | update source resolution (origin/env) + no-downgrade version comparison |
| `tests/test_realstore_readonly.sh` | uses a real cert store **read-only** (hashes unchanged, no `sudo`) |
| `tests/test_cli.sh` | CLI parsing, flag precedence, usage/exit codes, end-to-end unprivileged PKI |
| `tests/pki.bats` | BATS mirror of the core unprivileged-PKI guarantees |

Requirements: `bash`, `nebula-cert` (for PKI tests; auto-skipped otherwise).
BATS tests run when `bats` is installed. `test_realstore_readonly.sh` targets
`/home/ulno/keys/nebula` by default (override with `NEBULA_TEST_STORE`) and
skips when absent — it never writes to that store.

`make lint` syntax-checks the entrypoint and all modules (and runs `shellcheck`
when available).

---

## 🖥️ Preview

<details>
  <summary><b>👀 Click to expand</b></summary>
  <p align="center">
    <a href="resources/img/server-selection.png"><img src="resources/img/server-selection.png" alt="Server selection" width="300" loading="lazy"></a>
    <a href="resources/img/main-menu.png"><img src="resources/img/main-menu.png" alt="Main menu" width="300" loading="lazy"></a>
    <a href="resources/img/connectivity-menu.png"><img src="resources/img/connectivity-menu.png" alt="Connectivity menu" width="300" loading="lazy"></a>
    <br/>
    <a href="resources/img/cert-menu.png"><img src="resources/img/cert-menu.png" alt="Certificates menu" width="300" loading="lazy"></a>
    <a href="resources/img/config-menu.png"><img src="resources/img/config-menu.png" alt="Config menu" width="300" loading="lazy"></a>
    <a href="resources/img/maintenance-menu.png"><img src="resources/img/maintenance-menu.png" alt="Maintenance menu" width="300" loading="lazy"></a>
  </p>
</details>

---

## 📚 Official Nebula resources

- **Nebula Docs (home):** https://nebula.defined.net/docs/
- **Quick Start:** https://nebula.defined.net/docs/guides/quick-start/
- **Configuration Reference (all keys):** https://nebula.defined.net/docs/config/
- **`static_host_map` explainer:** https://nebula.defined.net/docs/config/static-host-map/
- **Example `config.yml`:** https://raw.githubusercontent.com/slackhq/nebula/master/examples/config.yml
- **Releases (downloads):** https://github.com/slackhq/nebula/releases
- **GitHub repo:** https://github.com/slackhq/nebula

---

## ❓ FAQ

Looking for more answers? Check the [Full FAQ on GitHub Wiki »](https://github.com/jordanhillis/nebula-manager/wiki/FAQ)

---

## 🩺 Runtime notes

- **Your config lives with you by default.** `nebula-manager.conf` is resolved as
  `--config` / `$NEBULA_MANAGER_CONF` → an existing
  `/etc/nebula/nebula-manager.conf` → `$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf`.
  The per-user default means a first run never needs root just to fetch a config
  template. Force a location with `--config <path>`.
- **Privilege requests explain themselves.** Before any `sudo` password prompt the
  tool prints the reason and the exact command it is about to run, e.g.:
  ```
  [!] Administrator privileges required: restart the Nebula service
      command: sudo systemctl restart nebula
  ```
  It only ever asks for the specific privileged action, never for the whole session.
- **Nebula often runs as a service user.** Files under `/etc/nebula` may be owned by
  `nobody` (or the unit's `User=`), so the tool reads them read-only and only
  elevates for the read when necessary. If the config isn't readable, diagnostics
  falls back to sane defaults and says so.
- **`listen.port: 0` means an OS-assigned port.** Diagnostics resolves the port in
  this order: explicit `listen.port` → auto-detection (via `ss`, using passwordless
  `sudo` when available, or an opt-in elevated lookup on a TTY) → `default_port`.
  Set `default_port` to your usual port (e.g. `4545`) to avoid ambiguity.
- **Systemd (not containers), for now.** The tool assumes Nebula runs as a host
  systemd unit. Pod/container support is a TODO (see below).
- **Update checks follow your source repo, not upstream.** The version check and
  self-update resolve the repo as `NEBULA_MANAGER_REPO` → git `origin` → built-in
  upstream (`jordanhillis/nebula-manager`), so a fork checks itself. An update is
  only offered when the published version is **strictly newer** (semantic
  comparison), never as a downgrade. Git checkouts are never auto-overwritten —
  the tool tells you to `git pull` instead.

---

## 🔄 Update checks & forks

Nebula Manager checks for newer versions of **itself** at startup (and via
`--auto-update-nebula`). Where it checks depends on where your copy came from,
in this order:

1. `NEBULA_MANAGER_REPO` (`owner/repo`), if set
2. the git remote **`origin`** of the checkout it is running from
3. the built-in upstream: **`jordanhillis/nebula-manager`**

So a fork checks *itself* by default. An update is only offered when the
published version is **strictly newer** than the running one (version-aware
comparison, e.g. `1.10 > 1.9`) — a fork that is ahead of upstream is never
offered a downgrade. The result is cached per repo for 6 hours at
`/tmp/nebula-manager-version-<owner>_<repo>.cache`.

### Checking upstream explicitly

To compare against the canonical project instead of your fork, point the check
at the upstream repo:

```bash
# one-off
NEBULA_MANAGER_REPO=jordanhillis/nebula-manager ./nebula-manager

# for the current shell / a CI job
export NEBULA_MANAGER_REPO=jordanhillis/nebula-manager
```

Pick a specific branch or tag with `NEBULA_MANAGER_REF`:

```bash
NEBULA_MANAGER_REPO=jordanhillis/nebula-manager NEBULA_MANAGER_REF=main ./nebula-manager
```

Confirm what is being checked with `paths`:

```bash
./nebula-manager paths      # -> update-repo: ulno/nebula-manager@main
```

### Disabling the check

Set `disable_version_check=true` under `[global]` in `nebula-manager.conf`.
(The same setting also silences the "update available" prompt.)

### What accepting an update does

- **Git checkout:** the tool never overwrites your working tree. It prints the
exact command to use instead (`git -C <dir> pull --ff-only`).
- **File install:** it downloads the entrypoint **and** `lib/*.sh` from the
resolved repo, verifies the entrypoint's SHA-256 against the published
`nebula-manager.sha256`, and only uses `sudo` if the install path requires it.

`NEBULA_MANAGER_DEFAULT_REPO` overrides the last-resort fallback (step 3) and is
mainly useful for testing.

---

## 📖 User stories

Two guiding examples drive the workflow and act as the acceptance criteria for
planned features — see **[docs/user-stories.md](docs/user-stories.md)**:

1. **Ulno, the networking teacher** — import an existing hand-rolled Nebula mesh,
   add two more home machines, and hand out per-student profile collections.
2. **The students** — join Ulno's mesh from Windows, Linux and macOS.

The first story makes the case for a top priority: on a host where Nebula is
*already running*, **discover the installation and offer to generate
`nebula-manager.conf`** instead of asking for a config that doesn't exist yet.

---

## 🧭 Roadmap / TODO

- [ ] **`import` wizard** – detect a running Nebula (service, binaries, config,
      certs, `tun.dev`, `listen.port`, lighthouse role) and generate
      `nebula-manager.conf`; never silently elevate (show reason + command).
- [ ] **`server add`** – build `[server.*]` sections from a live install.
- [ ] **`client-setup <bundle>`** – install a bundle + service on a new host.
- [ ] **`profile create`** – group collections (N bundles + CA + README/install).
- [ ] **Pod/container support** – detect Nebula running under `podman`/`docker` and
      route lifecycle actions through the container runtime instead of `systemctl`.
- [ ] **macOS `launchd`** service management; **Windows** guidance (WSL documented).
- [ ] Optional `nebula-cert` JSON health checks / richer diagnostics output.

---

## 🔒 Security Notes
- The tool runs **unprivileged**; review any `sudo` prompt before approving it.
- Keep backups of your `config.yml` and certificates before making changes.
- Only run Nebula Manager on trusted systems — it manages cryptographic keys.
- Keep certificate workspaces user-owned (mode `700`) to avoid ever needing root.

---

## 📄 License

[MIT](/LICENSE) — free to use, modify, and distribute.

---

## 🤝 Contributing
Pull requests are welcome. For major changes, open an issue first to discuss what you'd like to change.

---

## 🧠 Author

Created by [Jordan Hillis](https://github.com/jordanhillis). Contributions welcome!
