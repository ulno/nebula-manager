# User stories & guiding examples

These two stories are the **guiding examples** for nebula-manager's workflow. They
describe the intended end-to-end experience and double as a spec: steps marked
**⚙️ planned** are not implemented yet and exist to steer development; steps
marked **✅ today** work with the current tool.

> Motivation: on a host where Nebula is **already installed and running**, the
> first thing the tool should do is **discover what is there** and offer to
> generate `nebula-manager.conf` from it — not ask for a config that the user
> doesn't have yet. See *Story 1 / Phase 0*.

## The two config files (don't mix them up)

| File | Purpose | Typical location |
|---|---|---|
| **`nebula-manager.conf`** | the **tool's** config: `[global]` + `[server.NAME]` sections | `~/.config/nebula-manager/nebula-manager.conf` (or `/etc/nebula/nebula-manager.conf`) |
| **Nebula `config.yml`** | **Nebula's** runtime config: `pki`, `lighthouse`, `listen`, `firewall`, `tun` | `/etc/nebula/config.yml` |

The tool *manages* Nebula `config.yml` files, and *is configured by* `nebula-manager.conf`.

---

## Using it from the TUI (the main way)

Start the tool and everything is selectable from the text-graphical menus:

```bash
./nebula-manager        # or: nebula-manager
```

| Menu | Use it for |
|---|---|
| **Setup** | shows the detected state, then Import/Update / Create / Browse / Edit / Delete config, Manage servers, Certificate Workspace |
| **Servers** | List / Add / Enable-Disable / Remove `[server.*]` |
| **Certificates** | List / Create CA / Sign / View / Expiry / **Bundle client zip** / Revoke / Switch workspace |
| **Configuration** | Validate / Edit Nebula `config.yml` / Firewall |
| **Connectivity** | ping all cert IPs (+ optional `iperf3`) |
| **Diagnostics** | TUN ip, UDP socket, cert expiry |
| **Benchmarks** | `iperf3` server / client |
| **Maintenance** | service toggle / update / auto-update scheduler / install / remove |

With no config yet, the tool opens **Setup** for you, showing what it detected
on this host (Nebula installed? a config already present? cert workspace?) before
offering to import, create or browse for one. The command lines shown in the
phases below are the **expert/automation** equivalents of the same menus.

---

## Story 1 — Theprof, the networking teacher

**Situation.** Theprof teaches a Nebula class. He already runs Nebula by hand:

- a **lighthouse** on a VPS: `vps.theprof.mesh` = `10.100.0.1`, reachable at
  `vps.theprof.demo:4545`;
- his laptop `theprof-framework.theprof.mesh` = `10.100.0.2` (a **client**);
- an existing **CA** with certs in `~/keys/nebula` (CA name `TheprofMeshCA`);
- Nebula runs as a **systemd service** (as the `nobody` user), so
  `/etc/nebula/config.yml` is root/service-owned;
- `listen.port: 0` (the OS assigns the UDP port, e.g. `54143`).

He does **not** use nebula-manager yet. He wants to: (a) import this setup,
(b) add two more home machines, (c) hand out per-student profiles.

```mermaid
graph TD
  L["vps.theprof.mesh - lighthouse - 10.100.0.1:4545"]
  U1["theprof-framework - 10.100.0.2"]
  U3["theprof3 - 10.100.0.4"]
  U4["theprof4 - 10.100.0.5"]
  G1["student-group-1 - 10.101.0.0/24"]
  G2["student-group-2 - 10.102.0.0/24"]
  L --- U1
  L --- U3
  L --- U4
  L --- G1
  L --- G2
```

### Phase 0 — Import the existing setup (✅ available)

**TUI:** *Setup ▸ Import / update from this host*.

Today he would have to create a config by hand. The **intended** experience is a
single discovery pass (✅ available):

```bash
$ nebula-manager import
Detected a running Nebula installation:
  service:      nebula.service (active)
  nebula:       /usr/bin/nebula (v1.11.2)
  config:       /etc/nebula/config.yml   (service-owned; readable with sudo)
  certs:        /home/theprof/keys/nebula   (CA: TheprofMeshCA, 3 certs)
  tun:          nebula1 (10.100.0.2/24, up)
  lighthouse:   10.100.0.1 -> vps.theprof.demo:4545
  this host:    client (am_lighthouse: false)

Proposed nebula-manager.conf -> ~/.config/nebula-manager/nebula-manager.conf

  [global]
  bin_path=/usr/bin
  cert_dir=/home/theprof/keys/nebula
  default_port=4545

  [server.theprof-framework]
  dir=/etc/nebula
  service=nebula.service
  enabled=true

Write this file? [Y/n]
```

What the importer detects:

- **service(s):** `systemctl list-units/list-unit-files 'nebula*'` → unit name + `FragmentPath`, and the `-config` path from the unit's `ExecStart` (falls back to `/etc/nebula/config.yml`). If `systemctl` cannot reach the bus (containers, restricted shells) it **scans the unit files on disk** (`/etc/systemd/system`, `/run/systemd/system`, `/usr/lib/systemd/system`, `…/systemd/user`) instead.
- **binaries:** `command -v nebula` → proposes `bin_path`.
- **config keys:** `tun.dev`, `listen.port`, `lighthouse.am_lighthouse`, the first `static_host_map` peer, and `pki.ca` (whose directory becomes `cert_dir`).
- **certs:** the `pki` directory, else any detected store (`$NEBULA_KEYS_DIR`, `~/keys/nebula`, `$NEBULA_DIR/certs`, the default); counts `*.crt`.
- **port:** `listen.port`, or auto-detection when it is `0`/unset (same logic as `diag`).
- **read-only:** a privileged config is read only via a readable copy that **asks first and shows the reason + command** before any sudo prompt.

Flags: `--dry-run` (print only), `--yes` (write non-interactively), `--force`
(overwrite), `--from CONFIG` (use a specific Nebula config for discovery),
`--config OUT` (output path). It refuses to write without confirmation on a
non-tty unless `--yes` is given. Re-running it over an existing config keeps a
timestamped backup (`*.bak.YYYYmmdd-HHMMSS`) and updates in place. If nothing is
detected it falls back to:

```bash
nebula-manager config init          # write ~/.config/nebula-manager/nebula-manager.conf
nebula-manager config edit          # replace [server.nebula-example1] with your real server(s)
```

### Phase 1 — Register the existing members (✅ available)

**TUI:** *Servers ▸ Add Server* (list/enable/disable/remove in the same menu).

```bash
$ nebula-manager server add theprof-framework --dir /etc/nebula --service nebula.service
$ nebula-manager server add vps --role lighthouse --dir /etc/nebula --host vps.theprof.demo:4545
$ nebula-manager cert list --cert-dir ~/keys/nebula
  Name                          Type  IPs            Groups
  TheprofMeshCA                    CA    -              -
  theprof-framework.theprof.mesh      Cert  10.100.0.2/24  laptops
  vps.theprof.mesh              Cert  10.100.0.1/24  lighthouse,servers
```

Other subcommands: `server list` (table of `[server.*]` entries), `server remove NAME`,
`server enable|disable NAME`. `role`/`host` are stored as informational metadata;
the functional keys are `dir`, `service`, `enabled`.

### Phase 2 — Add home machines theprof3 and theprof4 (mostly ✅ today)

**TUI:** *Servers ▸ Add Server*, *Certificates ▸ Generate Client Certificate*,
*Certificates ▸ Bundle Client Zip*.

Sign certs unprivileged in the existing workspace. In the TUI the name and IP
are **pre-filled from the existing certs** (domain suffix `.theprof.mesh`, next
free address `10.100.0.4/24`) — just press Enter to accept:

```
[?] Enter the certificate name [theprof-framework.theprof.mesh]: theprof3.theprof.mesh
[?] Enter the IP address [10.100.0.4/24]:
[?] Enter the IP address [10.100.0.5/24]:    # next cert, after .4 is used
```

```bash
$ nebula-manager sign --cert-dir ~/keys/nebula \
      --name theprof3.theprof.mesh --ip 10.100.0.4/24 --groups laptops
$ nebula-manager sign --cert-dir ~/keys/nebula \
      --name theprof4.theprof.mesh --ip 10.100.0.5/24 --groups laptops

$ nebula-manager cert bundle theprof3.theprof.mesh ./bundles
$ nebula-manager cert bundle theprof4.theprof.mesh ./bundles
```

Each bundle (`./bundles/theprof3.theprof.mesh-nebula-bundle.zip`) contains the cert, key,
`ca.crt` and a `config.yml.template` (with `static_host_map`/`lighthouse.hosts`
placeholders). He also edits the **firewall** so home machines can talk to each
other without restrictions:

```yaml
firewall:
  inbound:
    - port: any
      proto: any
      group: laptops          # laptops talk to laptops
  outbound:
    - port: any
      proto: any
      host: any
```

On each new machine (✅ today, manual):

```bash
git clone https://github.com/<you>/nebula-manager    # brings ./nebula-manager + ./lib
cd nebula-manager
./nebula-manager config init                         # create the tool config
./nebula-manager config edit                         # add [server.theprof3] with dir/service
unzip ~/theprof3.theprof.mesh-nebula-bundle.zip -d ~/nb
# install Nebula + place files (sudo only where needed):
sudo install -d /etc/nebula
sudo cp ~/nb/{ca.crt,theprof3.theprof.mesh.crt,theprof3.theprof.mesh.key} /etc/nebula/
sudo cp ~/nb/config.yml.template /etc/nebula/config.yml   # then edit static_host_map + lighthouse.hosts
./nebula-manager            # TUI -> Maintenance -> install/enable the service, then Toggle
./nebula-manager diag       # verify TUN ip, UDP socket, cert expiry
```

⚙️ Planned convenience: `nebula-manager client-setup <bundle.zip>` that unpacks,
places files under `/etc/nebula`, patches the unit's config path, enables the
service, and runs `diag` — elevating only for the individual system steps.

### Phase 3 — Two student groups of three machines (⚙️ planned "profiles")

**TUI:** ⚙️ planned *Profiles ▸ Create group*.

Theprof wants two isolated class networks and a ready-to-hand-out collection per
group. ⚙️ Proposed:

```bash
$ nebula-manager profile create student-group-1 \
      --ca ~/keys/nebula \
      --lighthouse 10.100.0.1 \
      --subnet 10.101.0.0/24 \
      --members alice,bob,carol \
      --groups students,g1

$ nebula-manager profile create student-group-2 \
      --subnet 10.102.0.0/24 \
      --members dave,erin,frank \
      --groups students,g2

$ ls dist/
student-group-1/  student-group-2/
student-group-1/
  alice-nebula-bundle.zip
  bob-nebula-bundle.zip
  carol-nebula-bundle.zip
  ca.crt
  README.txt
  install.sh              # tiny helper; detects OS, places files, starts nebula
```

A **profile** bundles: per-member cert/key + `config.yml` template (lighthouse
pointed at `vps.theprof.demo:4545`), the shared `ca.crt`, and a `README` + install
script. Firewall rules restrict each group to its own `subnet`, so groups can't
see each other.

What a profile must produce (spec): certs with `--groups <group>` and a
`--subnets`/`local_cidr` scope, a `config.yml` per member, the CA, and a
portable install/README. This is essentially `cert bundle` × N + shared assets.

---

## Story 2 — The students join

Names: **Alex** (Windows 11), **Bianca** (Ubuntu), **Chen** (macOS).
Each receives `student-group-1/<their>-nebula-bundle.zip` (or the whole folder)
from Theprof.

### Bianca — Ubuntu ✅ (fully scriptable; Debian and Mint work the same)

Per-distribution details (Fedora/RHEL, Arch/CachyOS, SELinux, firewalls) are in
**[docs/linux-distros.md](linux-distros.md)**.

```bash
# Nebula + tooling from the Ubuntu archive
sudo apt update
sudo apt install -y nebula gawk curl findutils grep jq sed sudo systemd tar wget \
                    coreutils iperf3 iputils-ping whiptail zip
# yq v4 (only the firewall editor needs it): Ubuntu's archive yq is the old Python v3
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

git clone https://github.com/<you>/nebula-manager
cd nebula-manager
./nebula-manager config init
./nebula-manager config edit               # [server.student-group-1] dir=/etc/nebula service=nebula.service
unzip ~/bianca-nebula-bundle.zip -d ~/nb
sudo install -d /etc/nebula
sudo cp ~/nb/{ca.crt,bianca.*.crt,bianca.*.key,config.yml.template} /etc/nebula/
sudo mv /etc/nebula/config.yml.template /etc/nebula/config.yml
# edit /etc/nebula/config.yml: static_host_map + lighthouse.hosts
./nebula-manager          # Maintenance -> Toggle Nebula Service
./nebula-manager diag     # confirm 10.101.0.x/24 up, cert valid
```

> **Fedora:** `sudo dnf install -y nebula ... yq ...` (`yq` is v4 there).
> **Arch/CachyOS:** `sudo pacman -S nebula go-yq libnewt ...`.
> The rest of the steps are identical.

### Chen — macOS ⚙️ partial (bash tool works; service = launchd)

`nebula-manager` runs under bash on macOS, but the **service** layer is systemd-
only today. ⚙️ Planned: detect `launchd` and manage a `LaunchDaemon`
(`/Library/LaunchDaemons/net.defined.nebula.plist`) with the same "reason +
command" sudo prompts. For now:

```bash
brew install nebula
./nebula-manager diag                 # diagnostics work
# place files under /etc/nebula (sudo), then load a LaunchDaemon by hand
```

### Alex — Windows ⚙️ manual today (documented bridge)

nebula-manager is a bash tool; on Windows we ship the bundle plus instructions.

- **Option A (recommended):** WSL2 — follow Bianca's Ubuntu steps inside WSL
  (Nebula's TUN still binds to the host via WSL networking).
- **Option B (native):** download `nebula.exe`/`nebula-cert.exe` from the Nebula
  release matching the bundle, then place `ca.crt`, `alex.*.crt`, `alex.*.key`
  and `config.yml` (from the bundle) in `C:\ProgramData\nebula\`, and install the
  Nebula service (`nebula.exe -service install`, `-service start`).

⚙️ Planned: `nebula-manager profile` also emits a **per-OS README** and a
PowerShell snippet so Windows students have copy/paste steps; and a
`nebula-manager verify` mode that re-checks reachability to the lighthouse from
the student's machine.

---

## Capability map (today vs planned)

| Capability | Status |
|---|---|
| Create CA, sign certs, list/inspect/expiry, remove | ✅ today |
| Unprivileged cert workspace (`--cert-dir` / `NEBULA_KEYS_DIR` / auto-detect) | ✅ today |
| Client bundle (cert, key, `ca.crt`, config template) | ✅ today |
| Tool config resolution + `config init/refresh/edit` (offline template) | ✅ today |
| Diagnostics (TUN ip, UDP socket auto-detect, cert expiry) | ✅ today |
| iperf3 bench (server/client) | ✅ today |
| **`import`**: discover a running Nebula and generate `nebula-manager.conf` | ✅ today |
| **`server add/list/remove/enable/disable`**: manage `[server.*]` entries | ✅ today |
| **`client-setup <bundle>`**: install a bundle + service on a new host | ⚙️ planned |
| **`profile create`**: group collections (N bundles + CA + README/install) | ⚙️ planned |
| macOS `launchd` service management | ⚙️ planned |
| Windows support (native) | ⚙️ planned (WSL documented) |

These stories are the acceptance criteria for the planned commands above.
