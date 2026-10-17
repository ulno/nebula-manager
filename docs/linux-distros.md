# Linux distribution guides

`nebula-manager` runs on any systemd-based Linux. These are the tested paths for
the three families it auto-detects from `/etc/os-release`:

| Family | Detected as | Package manager |
|---|---|---|
| Ubuntu, Debian, Linux Mint, Pop!_OS | `debian` | `apt` |
| Fedora, RHEL, CentOS Stream, Rocky Linux, AlmaLinux | `redhat` | `dnf` |
| Arch Linux, CachyOS (and derivatives) | `arch` | `pacman` |

Distro packages install Nebula as a **systemd service**; `nebula-manager` detects
the unit and the `-config` path automatically (`./nebula-manager import`).

> **The `yq` trap.** The firewall editor needs **mikefarah yq v4**. The `yq`
> package in the Ubuntu/Mint/Debian archives is the old **Python v3** wrapper and
> is *not* compatible. Fedora's `yq` and Arch's `go-yq` are v4. If yq is missing
> or wrong, everything except the firewall editor still works.

Package names below were verified against Ubuntu 24.04 (noble), Debian 12/13
(bookworm/trixie), Fedora 43+ and Arch `extra`/`core`.

---

## Ubuntu (also Debian and Linux Mint)

### 1. Install Nebula

```bash
sudo apt update
sudo apt install -y nebula
```

On Ubuntu/Mint the `nebula` package lives in **universe** (enabled by default on
desktop/server installs).

The package provides:

| Path | What |
|---|---|
| `/usr/bin/nebula`, `/usr/bin/nebula-cert` | binaries |
| `/usr/bin/nebula-service` | helper |
| `/usr/lib/systemd/system/nebula.service` | unit |
| `/etc/nebula/config.yml` | default config |

Verify:

```bash
nebula --version
nebula-cert --version
systemctl cat nebula
```

> Ubuntu 24.04 ships Nebula **1.6.x** and Debian 13 (trixie) ships **1.9.x**.
> For the newest release use the upstream tarball (see *Upstream binaries*).

### 2. Install nebula-manager's tools

```bash
sudo apt update
sudo apt install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils \
                    iperf3 iputils-ping whiptail zip
```

**yq v4 (only needed for the firewall editor).** Ubuntu/Mint and Debian 12 do
*not* package mikefarah v4 — `apt install yq` gives the incompatible Python v3.
Install the upstream static binary instead:

```bash
# amd64; use yq_linux_arm64 on arm64
sudo wget -qO /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq --version            # must report "... version v4.x"
```

On **Debian 13 (trixie)/sid** you can instead use `sudo apt install yq-go`
(also provides `/usr/bin/yq`).

### 3. Service, config and permissions

- Unit: `/usr/lib/systemd/system/nebula.service` (vendor unit — put overrides in
  a drop-in under `/etc/systemd/system/nebula.service.d/`).
- Config: `/etc/nebula/config.yml`.
- Depending on packaging the unit may run as an unprivileged user, and
  `/etc/nebula` may not be readable by your login account. `nebula-manager`
  handles this: it reads the config through `sudo` (asking once, showing the
  reason). Keep `/etc/nebula` readable by whatever user the unit runs as.

```bash
sudo systemctl enable --now nebula
systemctl status nebula
./nebula-manager import --dry-run     # detects the unit + /etc/nebula/config.yml
```

### 4. Host firewall (ufw)

The Nebula **overlay** firewall lives in `config.yml`; the **host** firewall must
allow the UDP listen port:

```bash
sudo ufw allow 4242/udp comment 'Nebula lighthouse'
sudo ufw status
```

If `listen.port: 0`, the OS assigns the port — read it from
`./nebula-manager diag` (or `ss -lunp`) and allow that port on a lighthouse.

### 5. Verify

```bash
./nebula-manager diag          # TUN IP, UDP socket, cert expiry
ping <peer-overlay-ip>
```

---

## Fedora (also RHEL / CentOS Stream / Rocky / AlmaLinux)

### 1. Install Nebula

```bash
sudo dnf install -y nebula
```

The RPM provides `/usr/bin/{nebula,nebula-cert,nebula-service}`,
`/usr/lib/systemd/system/nebula.service` and `/etc/nebula/config.yml`.

### 2. Install nebula-manager's tools

```bash
sudo dnf install -y gawk curl findutils grep jq sed sudo systemd tar wget coreutils \
                    iperf3 iputils newt zip yq
```

`yq` in Fedora is mikefarah **v4** (check `yq --version`); `newt` provides
`whiptail`.

### 3. SELinux

Fedora enables SELinux (enforcing).

- **Use the RPM** where possible — its binaries and unit are labelled correctly.
- If you install **upstream binaries** into `/usr/local/bin`, systemd can fail
  with `status=203/EXEC` because of SELinux labels. Either use the RPM, or label
  them:

  ```bash
  sudo dnf install -y policycoreutils-python-utils   # provides semanage
  sudo semanage fcontext -a -t bin_t '/usr/local/bin/nebula(-cert)?'
  sudo restorecon -v /usr/local/bin/nebula /usr/local/bin/nebula-cert
  ```

- Certs/config outside `/etc/nebula` may need `restorecon` too.
- Diagnose denials with `sudo ausearch -m avc -ts recent`.

### 4. Host firewall (firewalld)

```bash
sudo firewall-cmd --permanent --add-port=4242/udp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

### 5. Service and verify

```bash
sudo systemctl enable --now nebula
systemctl status nebula
journalctl -u nebula -e
./nebula-manager diag
```

---

## Arch Linux / CachyOS

### 1. Install Nebula

```bash
sudo pacman -Syu --needed nebula
```

The package provides:

| Path | What |
|---|---|
| `/usr/bin/nebula`, `/usr/bin/nebula-cert` | binaries |
| `/usr/bin/nebula-service` | helper |
| `/usr/lib/systemd/system/nebula.service` | unit |

Unlike Debian/Fedora it does **not** ship `/etc/nebula/config.yml`; create it
yourself. The unit runs `nebula -config /etc/nebula/config.yml`, and
`nebula-manager` can fetch the example template when it notices the file is
missing.

### 2. Install nebula-manager's tools

```bash
sudo pacman -S --needed gawk curl findutils grep jq sed sudo systemd tar wget \
                         go-yq coreutils iperf3 iputils libnewt zip
```

- `go-yq` is mikefarah yq **v4** and provides `/usr/bin/yq`. The old `yq`
  package conflicts with it — install `go-yq`.
- `libnewt` provides `whiptail`.

### 3. Service, config and permissions

```bash
sudo install -d -m 750 /etc/nebula
sudo systemctl enable --now nebula
systemctl status nebula
./nebula-manager import --dry-run
```

The Arch package's unit uses the upstream example service (no `User=`), so the
daemon runs as root. Some setups still chown `/etc/nebula` to an unprivileged
account; either way, `nebula-manager` reads a service-owned config through `sudo`
when needed.

### 4. Host firewall

Arch enables no firewall by default. If you use `nftables`, `iptables` or `ufw`,
allow the UDP listen port:

```bash
sudo ufw allow 4242/udp        # if using ufw
# nftables example (table/chain names depend on your setup)
sudo nft add rule inet filter input udp dport 4242 accept
```

### 5. Verify

```bash
./nebula-manager diag
ping <peer-overlay-ip>
```

---

## Upstream binaries (any distribution)

To run the latest Nebula release instead of the distro package:

```bash
V=1.11.2   # see https://github.com/slackhq/nebula/releases
curl -LO "https://github.com/slackhq/nebula/releases/download/v$V/nebula-linux-amd64.tar.gz"
tar xzf nebula-linux-amd64.tar.gz
sudo install -m 755 nebula nebula-cert /usr/local/bin/
```

`bin_path` defaults to `/usr/local/bin`, so nebula-manager finds them. If you
install elsewhere, set it in `nebula-manager.conf`:

```ini
[global]
bin_path=/usr/local/bin
```

**Do not run both** a distro package and upstream binaries in different
locations — be explicit about which one `bin_path` points at.

---

## Notes that apply everywhere

- **Ports:** a lighthouse needs a fixed, reachable UDP port
  (`listen.port: 4242` or your choice). Clients may use `listen.port: 0`.
  Open the *host* firewall for the lighthouse port; the Nebula overlay firewall
  is separate (`config.yml` → `firewall:`).
- **Updates:** `nebula-manager --auto-update` replaces the binary in `bin_path`.
  With distro packages, prefer your package manager (leave `bin_path` at
  `/usr/bin`), or switch to upstream binaries under `/usr/local/bin`.
- **Config ownership:** service-owned configs are read via a reason-showing
  `sudo` prompt; nothing is written unless you ask.
- **Diagnostics first:** `./nebula-manager diag` shows the TUN IP, the actual
  listening UDP socket and certificate expiry — the three usual suspects.
