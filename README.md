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
- 🛡 **Certificate management** – list, generate, view, bundle/export (with list + name matching), check expiry, and **revoke with reasons**.
- 🗝️ **Configurable certificate workspaces** – keep PKI in a user-owned store, switch at runtime, auto-detect existing stores.
- 📝 **Configuration management** – interactively edit `config.yml` with validation to prevent bad deploys.
- 🔥 **Firewall management** – control inbound/outbound rules, defaults, and conntrack settings.
- 📡 **Connectivity tools** – multi-node reachability & latency table.
- 🏁 **Benchmarks** – `iperf3` server/client modes with custom overlay IPs (unprivileged).
- 🩺 **Diagnostics** – one-shot view of TUN IP, listening UDP socket, and certificate expiry.
- 🔌 **Listen-port aware** – reads `listen.port`, auto-detects OS-assigned ports (`port: 0`), and honors a configurable `default_port`.
- 🖥 **Plain-first UI** – numbered menus by default (easy to debug/script), with a graphical `whiptail`-based picker used automatically for file/dir browsing when available; `NEBULA_UI=whiptail` forces the curses UI everywhere.
- 📋 **Service orchestration** – manage all enabled servers, with per-server status.
- ⏪ **Update Nebula with rollback** if download or config validation fails.
- ⏰ **Auto-update scheduler** – via cron (`nebula-manager --auto-update-nebula`).
- 🆕 **First-run setup** – if no config is found, prompts to **create (offline template)**, **browse**, or **download**.
- 🖥 **Interactive TUI _and_ headless subcommands** – script it your way.

---

## 🏗️ Architecture

The tool is a thin entrypoint plus five modules under `lib/`:

```
nebula-manager          # entrypoint: arg parsing, dispatch, TUI root + Setup menu
lib/
  ui.sh                 # colours, status badges, whiptail/dialog + plain menus
  pki.sh                # CA, signing, inspection, workspaces, client bundling
  bench.sh              # iperf3 server/client, connectivity, diagnostics
  system.sh             # elevate()/sudo, systemd, /etc/nebula, config & server mgmt
  import.sh             # discover an existing Nebula -> generate nebula-manager.conf
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
- **Editing a service-owned `config.yml`** (Configuration ▸ Edit Config / Edit Firewall) reads it through the same one-time-sudo path, edits a **user-owned working copy** with `yq`, and saves once at the end through `elevate()` with a timestamped `.bak.*` backup. `yq` never touches a file you cannot read/write.
- Reading a **service-owned** Nebula config (`/etc/nebula/config.yml`, often owned by `nobody`) goes through `readable_nebula_config()` for **explicit actions** (`diag`, Validate Config, `import`, client bundling): it uses cached `sudo` if available, otherwise asks once — showing the **reason and exact command** — before elevating. The prompt is tied to stderr (not stdout), so capturing command output never suppresses it. The derived values (TUN dev, listen host/port, lighthouse role and whether `lighthouse.hosts`/`static_host_map` are present) are cached in `$XDG_CACHE_HOME/nebula-manager/system-info`, so the **startup header needs no elevation on later runs** and no longer tells you to run the whole tool with `sudo`. If no cache exists yet, the header detects the `nebula*` interface itself **and warns that the config (and therefore the lighthouse/static_host_map) could not be verified**, pointing you to **Diagnostics** or **Configuration ▸ Validate Config** to authorize the first read. Once readable, the header flags missing `lighthouse.hosts`/`static_host_map` directly. Cached values are keyed by the **real** config path even when a temporary readable copy was used, so the next startup uses them. If the unprivileged `nebula -test` then fails because the referenced `pki.key`/`pki.crt` files are also service-owned, **Validate Config offers a one-time elevated re-test** (or uses already-cached sudo credentials) instead of reporting a misleading “invalid config”.

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

**Required:** `gawk` (`awk`), `curl`, `findutils` (`find`), `grep`, `jq`, `sed`, `sudo`, `systemd` (`systemctl`), `tar`, `wget`, `coreutils` (`sha256sum`), `iputils-ping`
**Optional:** `yq` — **mikefarah v4 only**, used by the config and firewall editors (Fedora `yq`, Arch `go-yq`, or the upstream binary); `iperf3` (bandwidth tests); `whiptail` (graphical file/dir picker; menus are plain by default); `zip` (client bundles; falls back to `tar.gz`)

> 📖 Per-distribution manuals (Ubuntu/Debian/Mint, Fedora/RHEL, Arch/CachyOS,
> including SELinux and firewall notes): **[docs/linux-distros.md](docs/linux-distros.md)**.

### Install all dependencies

**<img src="https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white" alt="Debian" height="20"/> / <img src="https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu" height="20"/> / <img src="https://img.shields.io/badge/Linux%20Mint-87CF3E?logo=linuxmint&logoColor=white" alt="Linux Mint" height="20"/>**
```bash
sudo apt update
sudo apt install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils iperf3 iputils-ping whiptail zip
```
⚠️ **Do not** `apt install yq` on Ubuntu/Mint/Debian 12 — that is the incompatible Python yq v3. Install mikefarah's v4 binary:
```bash
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq && yq --version   # should say v4.x
```
(Debian 13/trixie also has `yq-go` in its archive.)

**<img src="https://img.shields.io/badge/Fedora-51A2DA?logo=fedora&logoColor=white" alt="Fedora" height="20"/> / <img src="https://img.shields.io/badge/RHEL-EE0000?logo=redhat&logoColor=white" alt="RHEL" height="20"/> / <img src="https://img.shields.io/badge/CentOS-262577?logo=centos&logoColor=white" alt="CentOS" height="20"/> / <img src="https://img.shields.io/badge/Rocky%20Linux-10B981?logo=rockylinux&logoColor=white" alt="Rocky Linux" height="20"/> / <img src="https://img.shields.io/badge/AlmaLinux-3D348B?logo=almalinux&logoColor=white" alt="AlmaLinux" height="20"/>
```bash
sudo dnf install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils iperf3 iputils newt zip yq
```
(Fedora's `yq` is mikefarah v4; `newt` provides `whiptail`.)

**<img src="https://img.shields.io/badge/Arch%20Linux-1793D1?logo=arch-linux&logoColor=white" alt="Arch Linux" height="20"/> / <img src="https://img.shields.io/badge/CachyOS-00A3E0?logo=arch-linux&logoColor=white" alt="CachyOS" height="20"/>
```bash
sudo pacman -S --needed gawk curl findutils grep jq sed sudo systemd tar wget go-yq coreutils iperf3 iputils libnewt zip
```
(`go-yq` provides mikefarah yq v4 as `/usr/bin/yq`; `libnewt` provides `whiptail`.)

Supported distributions are auto-detected from `/etc/os-release` (Debian/Ubuntu, RHEL
family, Arch/CachyOS). On an unrecognised distribution the tool still runs as long
as the required tools are present — it just can't suggest the install command.

---

## 🔐 Certificates & workspaces

All PKI lives in a **certificate workspace** (a directory containing
`ca.crt`, `ca.key`, `<name>.crt`, `<name>.key`). Workspaces are ordinary
directories — keep them user-owned and no privilege is ever needed.

### Generating a client certificate

**Certificates ▸ Generate Client Certificate** (or `nebula-manager sign …`) walks
you through a name, IP, groups and optional subnets/duration. The name and IP
prompts come with **suggestions derived from the existing certs**:

- **name** — `<this-host-short-name><mesh-domain>`, where the domain is the most
  common suffix among existing cert names (e.g. `ulno-framework.ulno.mesh` when
  your certs are `vps.ulno.mesh`, `ulno-ge75.ulno.mesh`, …);
- **IP** — the **next free /24 host** in the overlay network used by most of your
  certs (e.g. `10.100.0.1`, `.2`, `.3` present → `10.100.0.4/24`).

Press Enter to accept a suggestion or type your own. The name is a free-form
label (Nebula does not require the domain), but keeping the `.mesh` suffix
matches the convention the rest of your certs follow.

If you type a **bare name** (no dot) while your existing certs use a mesh domain,
the TUI offers to append it: with **one** domain it asks for confirmation; with
**several** it shows a menu (most-used first, with counts) plus *keep as-is*.
`nebula-manager sign --name bare` only prints the same hint — it never renames
silently.

```
[?] Enter the certificate name [ulno-framework.ulno.mesh]:
[?] Enter the IP address [10.100.0.4/24]:
```

#### Mobile devices (Android / iOS)

The same TUI entry asks **“Is this certificate for a phone/tablet (Mobile Nebula)?”**.
For a mobile device you give it the **public key exported by the app** (the app
generates the keypair; the private key never leaves the phone), and it emits a
**QR code** you scan in the app:

```bash
# device exports device.pub from the app; then:
./nebula-manager sign --cert-dir ~/keys/nebula \
    --in-pub ~/device.pub \
    --name phone.mesh.example --ip 10.100.0.6/24 --groups mobile \
    --qr ~/keys/nebula/phone.png
```

- `--in-pub KEY.pub` — sign the device's public key; **no `.key` is written**.
- `--qr OUT.png` — write a QR code of the signed certificate to scan/copy into the
  app. (The QR contains the certificate only; the device already has the key.)
- Name/IP are still auto-suggested if omitted.

The app also needs the **CA certificate** (paste `ca.crt`, or scan a QR made with
`qrencode`), plus the lighthouse's overlay IP and public `host:port`. See
`docs/user-stories.md` (Story 1, Phase 2b / Story 2, Dana) for the full flow.

### Editing groups (batch)

Groups are baked into the certificate, so any group change means **re-signing the
affected certificates**. Instead of one hard-wired rename, nebula-manager uses a
**select → act** model (1–10 nodes is a comfortable checklist):

**Certificates ▸ Edit Groups (Batch)…**

1. type a **filter** — `all`, `group:laptops`, `without:home`, `name:theprof-*`,
   `ip:10.100.0.0/24` (unions and exclusions are supported);
2. confirm the matches in a **checkbox list** (all pre-selected; space toggles);
3. pick an **action**: add, remove, move, set or rename;
4. review the exact per-certificate diff and confirm;
5. optionally apply **another action to the same selection** (e.g. add `home`,
   then also add `admin`).

```text
Add group "home" to 2 certificate(s).
Originals are backed up as *.crt.bak; private keys are not touched.

theprof-framework.theprof.mesh.crt (10.100.0.2/24): [laptops,admin] -> [laptops,admin,home]
theprof-ge75.theprof.mesh.crt      (10.100.0.3/24): [laptops] -> [laptops,home]
```

| Action | Semantics |
|---|---|
| **add** | union — never replaces an existing group; already-present is a no-op |
| **remove** | subtract; absent is a no-op |
| **move A B** | add B and remove A **in one re-sign** (in-place, deduplicated) |
| **set** | replace the whole group list (`set ""` clears it) |
| **rename A B** | replace A with B only where A exists |

The conditional case is just a selection: *“remove `laptops` if `home` is
present, otherwise keep it”* = **select `group:home`, action remove `laptops`** —
certificates without `home` are never selected, so they stay untouched.

Headless equivalents (all support `--dry-run`, `--yes` and `--cert-dir DIR`):

```bash
./nebula-manager group list --cert-dir ~/keys/nebula

./nebula-manager group add home      --select group:laptops
./nebula-manager group remove laptops --select group:home
./nebula-manager group move laptops home --select group:laptops
./nebula-manager group set "home,admin" --select name:theprof-*
./nebula-manager group prune laptops --when group:home   # conditional remove
./nebula-manager group rename laptops home               # alias: rename-group

./nebula-manager group add test --select group:laptops --dry-run   # preview only
```

Selector grammar (repeat `--select` to union; `--exclude` subtracts):

| Spec | Matches |
|---|---|
| `all` | every non-CA certificate |
| `group:G` / `has:G` | certificates carrying group G |
| `without:G` / `missing:G` | certificates **not** carrying G |
| `name:GLOB` | certificate-name glob (`name:theprof-*`) |
| `ip:CIDR` / `ip:ADDR` | overlay address inside the CIDR / exactly ADDR |
| `cert:NAME` / `NAME` | exact certificate name (case-insensitive) |

What is preserved: **name, IP networks, subnets and expiry**. Duplicate groups
are removed and the original order is kept. Each original certificate is saved
next to itself as `<name>.crt.bak` (a pre-existing backup is never overwritten),
and the private key on the device is **not** touched — the re-issued certificate
is signed with a throwaway public key, so devices keep working with their
existing key.

Without `--yes` the CLI prints the preview and asks first; on a non-interactive
shell it refuses instead of re-signing silently. Batch actions require an
explicit `--select` (only `rename` defaults to `group:<old>`), so a missing
filter can never silently rewrite everything.

To give a **single** certificate more groups you can also re-sign it directly
(`nebula-manager sign --name … --ip … --groups a,b,c`), or use the batch editor
with `--select cert:<name>`.

### Exporting a client bundle

**Certificates ▸ Bundle / Export Client Certificate** lists every certificate
that can actually be exported (a matching `.crt` and `.key`), showing its
overlay IP and groups. CAs and mobile certs signed with `--in-pub` are skipped
because there is no local private key to ship. In **plain mode you can type a
(partial) name or path directly** at the selection prompt instead of picking a
number; the curses menu offers a *Type a certificate name manually…* entry.
Then confirm the output directory in a browser/prompt.

Headless usage accepts a **unique substring** (case-insensitive) instead of the
exact name, and lists candidates when the name is omitted or ambiguous:

```bash
./nebula-manager cert bundle                    # list exportable certificates
./nebula-manager cert bundle host1              # exact or unique substring
./nebula-manager cert bundle host1 --out ~/Downloads
./nebula-manager cert bundle host1 ./bundles    # positional dir still works
export NEBULA_BUNDLE_DIR=~/exports              # default destination
```

Destination precedence: `--out` → `NEBULA_BUNDLE_DIR` → the directory
nebula-manager was started in → `~/Downloads` → `~/tmp` → `$TMPDIR`. The zip
contains the cert, key, `ca.crt` and a `config.yml.template`, and is written
mode **0600** because it holds the private key.

The template is **populated from the running Nebula config** when one can be
read (`static_host_map`, `lighthouse.hosts`/`interval`, `punchy`, `listen`,
`tun` and the `firewall` policy). If no readable local config exists, it derives
lighthouses from the `[server.*]` entries plus the certificate workspace. Any
value it still cannot determine is left commented out, listed at the top of the
file, and reported as a warning — so a bundle never silently ships a config with
missing lighthouses.

### Importing a bundle on the client

**Setup ▸ Import client bundle (.zip/.tar.gz)** opens a file browser, extracts
the archive safely, validates `ca.crt` plus the matching `<name>.crt`/`<name>.key`,
and installs them together with the bundled `config.yml.template` (renamed to
`config.yml`, with `/etc/nebula` rewritten if you choose another target).

The install-directory menu explains the trade-off and offers a default:

```text
Where should the bundle be installed?

/etc/nebula is read by the system Nebula service (writes need sudo).
/home/you/nebula is user-owned (no sudo, but only manual runs use it).
Press Enter for /etc/nebula, or type a path directly.
  1. /etc/nebula (system service; needs sudo) [default]
  2. /home/you/nebula (user-owned; no sudo)
  3. Browse for a directory...
  4. Type a path...
```
Existing files are backed up with a timestamp; an existing `config.yml` is never
replaced without confirmation or `--force`. It then creates/updates
`nebula-manager.conf` (`[server.<name>]`, `dir=<target>`, `role=client`), offers
to **enable and start the systemd service** when it is installed but not running,
and reloads straight into the main menu.

Headless equivalent:

```bash
./nebula-manager import --bundle ~/Downloads/client-nebula-bundle.zip --yes
./nebula-manager import --bundle bundle.tar.gz --dir /srv/nebula --yes --force
./nebula-manager import --bundle bundle.zip --dry-run   # inspect, write nothing
```

Only the writes are elevated (via the usual reasoned sudo prompt); extraction and
validation happen as your normal user.

### Resolution precedence

1. `--cert-dir <path>` (CLI flag — highest priority)
2. `NEBULA_KEYS_DIR` environment variable
3. The saved interactive selection (chosen from **Certificates ▸ Switch Certificate Workspace**)
4. The active server's legacy directory: `$NEBULA_DIR/$cert_folder`
5. Default fallback: `$HOME/.local/share/nebula-manager/keys`

Use **Certificates ▸ Switch Certificate Workspace** to point the tool at a
different store; the choice is persisted in
`$XDG_CONFIG_HOME/nebula-manager/certdir`.

### Store history, backups & git

Every certificate-store write is recorded in **`<cert-dir>/nebula-manager.log`**
(timestamp, user, host, action; mode `600`). Before a certificate is
**overwritten, re-signed or removed**, the old state is preserved using one of
two strategies:

- **git mode** — if the store is inside a git work tree, pending certificate
  changes are committed first (`nebula-manager: pre-change snapshot (…)`).
  Private keys are **never** committed: `*.key`, `backups/`, `*.crt.bak`,
  archives and QR images are excluded via a nested `.gitignore` and an explicit
  staging pathspec.
- **folder mode** — otherwise a datestamped folder is written:
  ```text
  <cert-dir>/backups/20261024-160032-000-sign-host1-overwrite/
      host1.crt  host1.key  ACTION.txt        # files are mode 600
  ```
  `ACTION.txt` records time, user, host, reason and the file list.

If a git commit cannot be made (no usable repo/identity), the tool **falls back
to a folder backup**, so an overwrite is never left unprotected. Re-signing
also signs into a temporary directory and only then installs the new files
(`nebula-cert` itself refuses to overwrite).

```bash
nebula-manager cert store status
nebula-manager cert store log -n 40
nebula-manager cert store backup --reason "before classroom demo"
nebula-manager cert store git-init      # safe: keys/backups are ignored
```

In the TUI: **Certificates ▸ Store Backup / Git** shows the VCS state, log size
and backup count, and offers *snapshot now*, *initialize git*, *show the log*.
When a folder backup is created and no git repo exists, a one-time hint points
at `cert store git-init`.

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

The **Certificates ▸ Workspace** menu later offers the same list (current store,
any detected stores, default, server dir, custom) and, in plain mode, **also
accepts a directory typed directly** at the prompt — so you can either enter a
menu number or type the path you mean. If `--cert-dir`/`NEBULA_KEYS_DIR` is set
it still wins over the saved selection, and the tool warns you when that happens.

---

## 🛠️ Usage

Nebula Manager is **menu-driven first**. Run it and everything is selectable from
the numbered menus (plain text by default; file/dir pickers pop up graphically
when `whiptail` is available). The same actions are also available as
headless subcommands for scripting — see *Expert / scriptable* below.

### Interactive (the main way)

```bash
./nebula-manager        # or just: nebula-manager   (once installed)
```

| Menu | What you can do |
|---|---|
| **Setup** | shows the **detected state** (config, Nebula service, cert workspace), then: import/update from this host, **import a client bundle (.zip/.tar.gz)**, create, browse, edit, delete `nebula-manager.conf`, manage servers, pick the certificate workspace |
| **Servers** | list / add / enable-disable / remove `[server.*]` entries |
| **Certificates** | list, create CA, sign, **edit groups in bulk** (add/remove/move/set/rename with a filter), view, expiry, **bundle/export** (pick from a list), revoke, switch workspace |
| **Configuration** | validate / edit Nebula `config.yml` (service-owned files are edited on a working copy and saved once with a timestamped backup), edit firewall rules with a **group picker + rule templates + explain**, **policy packs** (embed in bundles / apply / export), **name resolution (Nebula DNS)** |
| **Connectivity** | ping every cert IP; optional `iperf3` test |
| **Diagnostics** | TUN IP, listening UDP socket, certificate expiry; reads a service-owned config once with temporary sudo and caches the header values |
| **Benchmarks** | `iperf3` server / client |
| **Maintenance** | toggle the service, update Nebula, auto-update scheduler, install/remove |

**First run** (no config yet) opens the **Setup** menu, which shows what was
detected on this host and lets you *Import / update from this host* (adopt a
running Nebula), *Import client bundle* (install a `.zip`/`.tar.gz` produced by
`cert bundle`), *Create config from template*, or *Browse for a config file* —
then *Manage servers* to add your servers and *Reload & continue* to enter the
main menu.

Handy extras: menus are **plain numbered** by default (easy to script and debug);
file/directory browsing automatically uses `whiptail` when it is installed.
`NEBULA_UI=whiptail nebula-manager` forces the curses UI for the menus too.

Screen clearing is **off by default**, so the menu history, `DEBUG=learn`
commands and any errors remain visible for verification. Use `--clear-screen`
(or `NEBULA_CLEAR_SCREEN=1`) for the old full-screen behaviour.

### Expert / scriptable (the same actions as the menus)

```bash
# Setup / servers           (TUI: Setup, Servers)
./nebula-manager import                 # detect running Nebula -> propose nebula-manager.conf
./nebula-manager import --dry-run       # just show what was detected / proposed
./nebula-manager import --yes           # write it non-interactively
./nebula-manager import --bundle ~/Downloads/client-nebula-bundle.zip --yes
./nebula-manager import --bundle bundle.tar.gz --dir /srv/nebula --yes --force
./nebula-manager server add vps --dir /etc/nebula --service nebula.service --role lighthouse --host vps.theprof.demo:4545
./nebula-manager server list
./nebula-manager server disable lab
./nebula-manager server remove lab
./nebula-manager config init            # create ~/.config/nebula-manager/nebula-manager.conf
./nebula-manager config edit            # open it in $EDITOR
./nebula-manager config refresh         # pull the latest template from your repo
./nebula-manager config remove --force  # delete the active config

# Certificates               (TUI: Certificates)
./nebula-manager ca --name my-ca --duration 999999h --cert-dir ~/keys/nebula
./nebula-manager sign --name host1 --ip 10.42.0.2/24 --groups servers --cert-dir ~/keys/nebula
./nebula-manager sign --cert-dir ~/keys/nebula   # name+IP auto-suggested from existing certs
./nebula-manager sign --cert-dir ~/keys/nebula --in-pub ~/phone.pub --qr ~/keys/nebula/phone.png
#   ^ mobile: sign the device-generated public key; no .key written, QR for the app
./nebula-manager cert list
./nebula-manager cert expiry 30         # certs expiring within 30 days
./nebula-manager cert bundle             # list certificates that can be exported
./nebula-manager cert bundle host1       # exact or unique substring; writes to cwd
./nebula-manager cert bundle host1 --out ~/Downloads
./nebula-manager rename-group laptops theprof --cert-dir ~/keys/nebula
#   ^ re-signs every cert carrying 'laptops', keeps *.crt.bak; --yes to skip the prompt
./nebula-manager group list --cert-dir ~/keys/nebula
./nebula-manager group add home --select group:laptops --cert-dir ~/keys/nebula
./nebula-manager group move laptops home --select group:laptops
./nebula-manager group prune laptops --when group:home
#   ^ select → act: only certs with 'home' lose 'laptops'; others are untouched
./nebula-manager group set "home,admin" --select name:theprof-* --dry-run

# Benchmarks & diagnostics   (TUI: Benchmarks, Diagnostics)
./nebula-manager bench server --port 5201
./nebula-manager bench client 10.42.0.2 --time 15 --streams 4 --reverse
./nebula-manager diag                   # TUN IP, UDP socket, cert expiry

# Firewall                   (TUI: Configuration ▸ Edit Firewall)
./nebula-manager firewall explain --nebula-config /etc/nebula/config.yml
#   ^ read-only: defaults, every rule, and how many certs each group rule matches
./nebula-manager firewall groups --cert-dir ~/keys/nebula
#   ^ groups available to rules, with member counts
./nebula-manager policy new home --groups home --description "Home machines"
./nebula-manager policy list
./nebula-manager cert bundle theprof-ge75.theprof.mesh --policy home
./nebula-manager policy export --pack home --select group:home --out ./policies/
./nebula-manager policy apply --pack home --nebula-config /etc/nebula/config.yml

# Utilities
./nebula-manager paths                  # resolved config / key dirs, info cache + UI backend
./nebula-manager ui                     # which UI backend is active (menu + browse)
./nebula-manager auto-update            # update Nebula to latest
./nebula-manager --version
```

### Name resolution (Nebula DNS)

Nebula does not change your OS resolver automatically. Name resolution has two
halves:

**On the lighthouse** (`am_lighthouse: true`): **Configuration ▸ Name resolution
(Nebula DNS)** sets `lighthouse.serve_dns: true`, `lighthouse.dns.host` (the
overlay IP), `dns.port: 53`, and adds an inbound firewall rule for UDP/53. It
offers to restart the service.

**On a client:** the same menu shows the detected values and offers explicit
actions:

```text
Resolver DNS: <not configured>
DNS suffix:   <not configured>
Boot hook:    not installed

Client DNS actions
  1. Apply now (until reboot)
  2. Apply now + install boot hook (recommended)
  3. Back
```

Applying runs:

```bash
sudo resolvectl dns nebula1 10.100.0.1
sudo resolvectl domain nebula1 '~ulno.mesh'
```

Option 2 also installs `nebula-manager-resolved.service`, which reapplies the
settings after `nebula.service` starts. Only the mesh suffix is routed to
Nebula, so public DNS keeps working.

```bash
nebula-manager dns status       # role, interface, lighthouse IPs, resolver/hook
nebula-manager dns setup        # interactive action menu
nebula-manager dns apply        # client: apply now (until reboot)
nebula-manager dns persist      # client: apply + install the boot hook
nebula-manager dns lighthouse   # lighthouse: serve_dns + firewall UDP/53
```

Use the certificate name (`vps.ulno.mesh`) for overlay lookups; `vps.ulno.net`
is the public endpoint and stays with public DNS.

Limitations: the lighthouse only answers for hosts it has seen since it started;
automatic client setup requires `systemd-resolved` (`resolvectl`). Without it,
configure the lighthouse overlay IP as DNS for the Nebula interface manually.

### Firewall for groups

Nebula firewalls are **per host**, and rule `groups:` refer to the **peer's
certificate groups**. nebula-manager therefore provides three layers:

**1. Edit this host's rules with a group picker.**
**Configuration ▸ Edit Firewall ▸ Inbound/Outbound rules ▸ add/edit** opens a
checkbox list of every group found in the certificate workspace, with member
counts (`home (3 cert(s))`). Current groups are pre-checked; you can uncheck,
combine groups, or pick *Type a group name manually…* for a group that has no
certificates yet. No free-text group syntax to remember.

**2. Add common rules from templates.**
**Configuration ▸ Edit Firewall ▸ Add a group-based rule from a template:**

| Template | Result |
|---|---|
| Allow all from a group (inbound) | `port: any`, `proto: any`, `groups: [...]` |
| Allow a TCP/UDP port from a group | needs port + protocol |
| Allow SSH (tcp/22) from a group | fixed 22/tcp |
| Allow all outbound to a group | the same, in `outbound` |
| Restrict inbound to one group | the allow rule **plus** `inbound_action: drop` |

**3. See what the policy actually does.**
**Configuration ▸ Edit Firewall ▸ Show the effective policy** (or
`firewall explain`) prints a readable summary and flags rule groups that no
certificate carries (usually a typo):

```text
Nebula firewall: /etc/nebula/config.yml
Inbound default:  drop
Outbound default: accept

Inbound rules (1):
  #0  any      any     groups [home,admin] -> 3 cert(s) match

Outbound rules (1):
  #0  any      any     any peer

Groups in workspace:
  admin                1 cert(s)
  home                 3 cert(s)
```

Before saving, the editor shows a **unified diff of the firewall section** and
asks for confirmation; declining leaves the config untouched. Validation
(`nebula -test`) and the timestamped backup still run on commit.

```bash
nebula-manager firewall explain [--nebula-config FILE] [--cert-dir DIR]
nebula-manager firewall groups  [--cert-dir DIR]
```

### Policy packs (fleet)

A **policy pack** is a named firewall fragment stored user-side (no root):

```text
${XDG_CONFIG_HOME:-~/.config}/nebula-manager/policies/<name>.yml
```

```yaml
name: home
description: Home machines
groups: [home]          # suggestion metadata, not a firewall rule
firewall:
  inbound_action: drop
  inbound:
    - port: any
      proto: any
      groups: [home]
  outbound:
    - port: any
      proto: any
      host: any
```

**Create one from this host's firewall** (reads it once with the usual
one-time-sudo path if it is service-owned):

```bash
nebula-manager policy new home --groups home --description "Home machines"
nebula-manager policy list
nebula-manager policy show home
nebula-manager policy edit home
nebula-manager policy validate home
```

**Bundles:** when a certificate's groups intersect a pack's `groups`, the bundle
flow **offers** that pack. Headless runs only print a hint — nothing is embedded
unless you ask:

```bash
nebula-manager cert bundle theprof-ge75.theprof.mesh --policy home
nebula-manager cert bundle theprof-ge75.theprof.mesh --policy none   # opt out
```

The generated `config.yml.template` then carries the pack's `firewall:` section
(and a `# Firewall policy pack: home` header) instead of the detected rules.

**Existing fleet:** render the pack for every matching certificate. Each host
gets its own directory with the firewall fragment and copy/paste instructions:

```bash
nebula-manager policy export --pack home --select group:home --out ./policies/
# ./policies/theprof-ge75.theprof.mesh/firewall.yml
# ./policies/theprof-ge75.theprof.mesh/README.txt
```

Actual distribution stays explicit (scp/ansible/whatever you use).

**Apply here** (working copy, diff confirmation, validation):

```bash
nebula-manager policy apply --pack home --nebula-config /etc/nebula/config.yml
nebula-manager policy apply --pack home --yes        # scripted
```

In the TUI, packs live under **Configuration ▸ Edit Firewall ▸ Policy packs**,
where a pack can also be applied to the config currently being edited (the
firewall diff/confirm still applies on the way out), shown, edited or deleted.

### Global flags

| Flag | Description |
|---|---|
| `--config <path>` | Override `nebula-manager.conf` location |
| `--cert-dir <path>` | Certificate workspace (overrides everything) |
| `--ui auto\|plain\|whiptail\|dialog` | Force a UI backend |
| `--debug <levels>` | Debug mode: `warn\|log\|info\|learn\|all` (comma-separated; see below) |
| `-l`, `--learn` | Shorthand for `--debug=learn` |
| `--clear-screen` | Clear the screen between TUI redraws (default: keep the transcript) |
| `--no-clear-screen` | Keep the transcript (default) |
| `--no-color` | Disable coloured output |

### Environment variables

| Variable | Purpose |
|---|---|
| `NEBULA_KEYS_DIR` | Certificate workspace (2nd precedence, after `--cert-dir`) |
| `NEBULA_BUNDLE_DIR` | Default directory for exported client bundles (default: start dir, then `~/Downloads`, `~/tmp`) |
| `NEBULA_LOCAL_CONFIG` | Explicit Nebula `config.yml` used to populate generated client templates (default: active server dir, then `/etc/nebula/config.yml`) |
| `NEBULA_NO_LOCAL_CONFIG` | Set to `1` to skip auto-detecting the host's Nebula config for templates (an explicit `NEBULA_LOCAL_CONFIG` still applies) |
| `NEBULA_MANAGER_LIB` | Override the `lib/` module directory |
| `NEBULA_MANAGER_CONF` | Path to `nebula-manager.conf` (alias for `--config`) |
| `NEBULA_MANAGER_REPO` | `owner/repo` used for update checks / templates (default: git `origin`) |
| `NEBULA_MANAGER_REF` | Git ref (branch) used for update checks (default `main`) |
| `NEBULA_MANAGER_DEFAULT_REPO` | Last-resort repo when neither env nor git `origin` is available (default `jordanhillis/nebula-manager`) |
| `NEBULA_UI` | UI backend. Default (*unset*/`auto`) = **plain numbered menus**; `whiptail`/`dialog` are used automatically for file/dir browsing when available, or set one to force a curses UI everywhere |
| `NEBULA_NO_PROMPT` | Set to `1` to never prompt; unreadable privileged files are skipped instead of read via sudo (used internally for state detection) |
| `NEBULA_DEFAULT_PORT` | Fallback Nebula listen port for diagnostics (default `4242`) |
| `DEBUG` | Debug levels: `warn`, `log` (default), `info`, `learn`, `all` — same as `--debug` |
| `NEBULA_CLEAR_SCREEN` | Set to `1` to clear between TUI redraws (default: off, transcript preserved) |

### Debug modes (`DEBUG` / `--debug`)

`DEBUG=learn` is the teaching mode: **every `nebula` / `nebula-cert` command is
printed (to stderr) immediately before it runs**, so you can watch — and later
reproduce — what the menus actually do. Normal output is unchanged and stdout
stays clean for scripts. `-l` and `--learn` are direct shortcuts for
`--debug=learn`.

| Level | What you see |
|---|---|
| `warn` | only warnings/errors (hides normal info/success lines) |
| `log` | classic output (the default when `DEBUG` is unset) |
| `info` | classic output + resolved config/cert-dir and binary detection (stderr) |
| `learn` | classic output + each Nebula CLI command before execution (stderr) |
| `all` | `info` + `learn` |

Levels can be combined, e.g. `DEBUG=warn,learn` (quiet, but show commands).

```bash
# See the exact commands while signing a certificate
DEBUG=learn ./nebula-manager sign --cert-dir ~/keys/nebula --name host2 --ip 10.42.0.3/24

# Reproduce it by hand:
nebula-cert sign -name host2 -ip 10.42.0.3/24 \
  -ca-crt ~/keys/nebula/ca.crt -ca-key ~/keys/nebula/ca.key \
  -out-crt ~/keys/nebula/host2.crt -out-key ~/keys/nebula/host2.key

# Headless debugging: details and commands on stderr, data on stdout
DEBUG=all ./nebula-manager cert list > certs.txt

# Same via the flag, or the learn shorthand
./nebula-manager --debug=info paths
./nebula-manager --learn cert list
./nebula-manager -l cert list
```

The learn lines look like:

```text
[learn] /usr/bin/nebula-cert sign -name host2 -ip 10.42.0.3/24 -ca-crt ... -ca-key ... -out-crt ... -out-key ...
[learn] sudo systemctl restart nebula.service
```

---

## 🧩 Configuration: `nebula-manager.conf`

Nebula Manager reads an **INI-style** config (with sections). The path is
resolved as `--config` / `$NEBULA_MANAGER_CONF` → an existing
`/etc/nebula/nebula-manager.conf` → `$XDG_CONFIG_HOME/nebula-manager/nebula-manager.conf`.

### First run — and the Setup menu

If no `nebula-manager.conf` is found (or none has usable `[server.*]` entries),
the tool opens the **Setup menu** instead of dead-ending on a download. The menu
first shows what it **detected on this host**, then offers the ways to get a
config:

```text
┌───────────────────────┤ Main Menu > Setup ├────────────────────────┐
│ Config: none yet (~/.config/nebula-manager/nebula-manager.conf)    │
│ Nebula: installed (v1.11.2) - nebula.service running               │
│ Certificates: /home/you/keys/nebula (7 .crt)                       │
│                                                                    │
│  1. Import / update from this host                                 │
│  2. Create config from template                                    │
│  3. Browse for a config file                                       │
│  4. Edit config                                                    │
│  5. Delete config                                                  │
│  6. Manage servers                                                 │
│  7. Certificate workspace                                          │
│  8. Reload & continue                                              │
│  9. Exit                                                           │
└────────────────────────────────────────────────────────────────────┘
```

The status lines are recomputed on every redraw, so after an action (e.g.
import) you immediately see the new state. Reached from the main menu, the
Setup menu is the same but without *Exit* (it has a *Back* instead).

- **Import / update** runs the read-only detector (`lib/import.sh`): it finds the
  systemd unit, its `ExecStart … -config`, `tun.dev`, `listen.port`, the
  lighthouse setting, the first `static_host_map` peer and the pki directory,
  then proposes a `nebula-manager.conf`. Re-running it **updates** an existing
  config — a timestamped backup (`*.bak.YYYYmmdd-HHMMSS`) is kept first.
- **Create** copies the bundled template from `lib/`
  (`lib/nebula-manager.conf.template`) — **offline, no root**.
- **Browse** opens a file browser (a `whiptail` menu navigator, or dialog's
  native `--fselect`) and validates that the picked file really is a manager
  conf (not Nebula's own `config.yml`).
- **Delete** removes the active config (elevating only if it lives in a
  privileged directory such as `/etc/nebula`).

The menu never changes anything without an explicit choice, and never needs root
just to *show* the config or to write the per-user default under
`$XDG_CONFIG_HOME`.

### Managing the config headlessly

```bash
./nebula-manager config path                 # print the resolved config path
./nebula-manager config init [--force]       # create it from the bundled template
./nebula-manager config init --config /etc/nebula/nebula-manager.conf
./nebula-manager config edit                 # open it in $EDITOR
./nebula-manager config refresh              # download the latest template
./nebula-manager config remove [--force]     # delete the active config
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
| `tests/test_pki_suggest.sh` | client-cert name/IP suggestions: mesh-domain suffix + next free overlay address |
| `tests/test_mobile_cert.sh` | mobile certs: `--in-pub` signs a device key (no `.key` written), `--qr` emits a QR, plus the TUI “mobile device” flow |
| `tests/test_sudo_mock.sh` | `sudo` is invoked **only** for privileged target dirs; failure is surfaced |
| `tests/test_resolve_dir.sh` | `--cert-dir` > `NEBULA_KEYS_DIR` > saved selection > legacy dir > default |
| `tests/test_port.sh` | listen-port resolution: `listen.port` → auto-detect → `default_port` |
| `tests/test_distro.sh` | distro detection + Arch/CachyOS package mapping; unknown distro no longer hard-fails |
| `tests/test_workspace.sh` | certificate workspace selection + "already known" detection |
| `tests/test_workspace_menu.sh` | workspace selector: detected stores listed, number *or* typed path accepted, invalid input re-prompts, env-override warning |
| `tests/test_conf.sh` | config path resolution: user-first, `--config`/env override, bundled template + `config init` offline |
| `tests/test_setup.sh` | Setup state summary (detected config/servers/workspace), `config_use_file` validation, `config remove` without sudo for user paths |
| `tests/test_tui_menu.sh` | entrypoint Setup/bootstrap menu wiring (import/browse/delete/reload/exit) + the state-line refresh hook |
| `tests/test_sysinfo.sh` | header is cache-first (no sudo/prompt), falls back to the `nebula*` interface guess, points at Diagnostics; unreadable configs never spew `Permission denied` |
| `tests/test_template_online.sh` | optional (needs `NEBULA_TEST_ONLINE=1`) freshness check of the bundled template vs the repo |
| `tests/test_update.sh` | update source resolution (origin/env) + no-downgrade version comparison |
| `tests/test_realstore_readonly.sh` | uses a real cert store **read-only** (hashes unchanged, no `sudo`) |
| `tests/test_cli.sh` | CLI parsing, flag precedence, usage/exit codes, end-to-end unprivileged PKI |
| `tests/test_debug.sh` | `DEBUG` levels: `learn` prints Nebula CLI commands to stderr only, `warn` hides info, stdout stays clean |
| `tests/test_bundle.sh` | client export: candidate listing, substring/ambiguous matching, default output dir, TUI picker, mode 0600 |
| `tests/test_client_config.sh` | generated client template: real static_host_map/lighthouse/punchy/listen/tun/firewall from the local config, `[server.*]` fallback, and missing-value warnings |
| `tests/test_edit.sh` | privileged-safe config editing: working copy for read-only/unreadable configs, elevated write-back, timestamped backup, and no-op when nothing changed |
| `tests/test_import_bundle.sh` | client bundle import: tar.gz extraction, validation, path rebasing, manager.conf creation, overwrite/backup, dry-run, TUI wrapper, CLI, post-import `--start` |
| `tests/test_dns.sh` | Nebula DNS: lighthouse `serve_dns` + UDP/53 firewall, client `resolvectl` DNS/domain setup, status output, static_host_map fallback |
| `tests/test_rename_group.sh` | group migration: preview/scan, dedup + order, re-sign preserves name/IP/expiry, unaffected certs/keys byte-identical, `*.crt.bak`, no sudo, CLI `--yes`/non-tty refusal |
| `tests/test_group_batch.sh` | selector grammar (`group`/`without`/`name` glob/`ip` CIDR/`cert`/union/exclude) + batch add/remove/move/set/prune, idempotency, `--dry-run`, non-tty refusal, `group list`, plain checklist parsing |
| `tests/test_firewall_groups.sh` | firewall group discovery/counts, picker (defaults/manual/unknown groups), rule templates, editor picker wiring, explain (defaults/matches/typo warning), diff + save prompt, CLI |
| `tests/test_policy_packs.sh` | policy packs: create/list/show/validate, group-based suggestions, embedding in generated configs/bundles (CLI + TUI), per-host export, apply (working copy + `--yes`), delete, no sudo |
| `tests/test_store_history.sh` | store action log; datestamped backups before overwrite/group/CA/remove; git snapshots with keys/backups excluded; CLI `cert store status/log/backup/git-init`; no sudo |
| `tests/pki.bats` | BATS mirror of the core unprivileged-PKI guarantees |

Requirements: `bash`, `nebula-cert` (for PKI tests; auto-skipped otherwise).
BATS tests run when `bats` is installed. `test_realstore_readonly.sh` uses a real
store from `$NEBULA_TEST_STORE` (unset by default, so it skips) and only ever
reads from it — no paths or names are hardcoded.

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
./nebula-manager paths      # -> update-repo: theprof/nebula-manager@main
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

1. **Theprof, the networking teacher** — import an existing hand-rolled Nebula mesh,
   add two more home machines, and hand out per-student profile collections.
2. **The students** — join Theprof's mesh from Windows, Linux and macOS.

The first story makes the case for the **`import`** wizard — on a host where Nebula
is *already running*, discover the installation and offer to generate
`nebula-manager.conf` instead of asking for a config that doesn't exist yet.
**This is now implemented** (`nebula-manager import`).

### Distribution guides

- **[docs/linux-distros.md](docs/linux-distros.md)** — install Nebula and
  nebula-manager's tools on **Ubuntu/Debian/Linux Mint**, **Fedora/RHEL**, and
  **Arch Linux/CachyOS**. Covers distro package contents, service/config paths,
  SELinux (Fedora), host firewalls (ufw/firewalld/nftables), upstream binaries,
  and the **yq v4** requirement for the config/firewall editors.

---

## 🧭 Roadmap / TODO

- [x] **`import` wizard** – detect a running Nebula (service, binaries, config,
      certs, `tun.dev`, `listen.port`, lighthouse role) and generate
      `nebula-manager.conf`; never silently elevate (show reason + command).
- [x] **`server add/list/remove/enable/disable`** – manage `[server.*]` entries
      (idempotent add, informational `role`/`host`).
- [ ] **`client-setup <bundle>`** – install a bundle + service on a new host.
- [ ] **`profile create`** – group collections (N bundles + CA + README/install).
- [x] **Mobile certificates** – `sign --in-pub KEY.pub` signs a device-generated
      public key (no `.key` written) and `--qr OUT.png` emits the QR scanned by
      **Mobile Nebula** (Android/iOS); also available in the TUI with the
      “Is this certificate for a phone/tablet?” prompt.
- [x] **Batch group editing** – selector + add/remove/move/set/rename/prune.
- [x] **Firewall policy packs** – group-targeted packs embedded in bundles,
      applied locally, or exported per host for an existing fleet.
- [x] **Certificate-store history** – action log, datestamped backups, optional
      git snapshots (private keys always excluded).
- [ ] **Remote fleet push** – push a rendered config/policy (and optionally
      refreshed certificates) to hosts over SSH, using the `policy export`
      output as the source; keep it explicit, host-scoped and dry-runnable.
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

**Academic improvements by ulno** — the least-privilege (non-root) refactor, the
modular `lib/` layout, the `import` wizard, server management, the plain-first
TUI, mobile certificate support and the per-distribution manuals — were developed
for teaching Nebula in a networking class.
