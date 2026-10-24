# OpenBSD MAP-E CE support

This repository contains experimental patches and utilities to add Customer Edge
Mapping of Address and Port with Encapsulation (MAP-E CE,
[RFC 7597](https://datatracker.ietf.org/doc/html/rfc7597)) support to
[OpenBSD](https://www.openbsd.org/) 7.9.

## Repository layout

The OpenBSD patches and the `maped` companion app are maintained together,
with separate component tests and installation targets:

```text
openbsd/
  patches/7.8/    Historical 7.8 patches and split DHCPv6 patches
  patches/7.9/    Current 7.9 PF and DHCPv6 patches
  src/           Patched OpenBSD 7.9 source snapshots and native regressions
  tests/         Portable PF harnesses and OpenBSD validation procedure
maped/
  bin/           Daemon and helper executables
  lib/           Perl modules
  etc/           Configuration and rc.d service script
  man/           maped(8) manual
  tests/         Unit tests, mocked integration tests, and fixtures
metrics/         Optional Prometheus exporter, dashboard, and tests
examples/        Complete deployment examples
docs/            Shared architecture and operational documentation
```

Run `make test` from the repository root for all portable component tests.
Individual suites are available with `make -C maped test`,
`make -C metrics test`, and `make -C openbsd test`. The PF suite uses the
bundled source snapshot by default; use `make pf-test OPENBSD_SRC=/usr/src`
to test a patched system source tree instead. Native OpenBSD validation is
covered in [the validation guide](openbsd/tests/OPENBSD79.md).

`make install` (or `make -C maped install`) installs only maped; the optional
exporter uses `make metrics-install` (or `make -C metrics install`). Installed
paths remain unchanged. Applying patches and rebuilding OpenBSD is a separate,
manual operation described below. Release tags `v7.8` and `v7.9` preserve their
original release snapshots.

## How it works

MAP-E ([RFC 7597](https://datatracker.ietf.org/doc/html/rfc7597)) carries IPv4
traffic across an IPv6-only ISP network by encapsulating IPv4 packets inside
IPv6 (`ip4-in-ip6`, protocol 4) and sharing a public IPv4 address across
multiple Customer Edge (CE) routers using deterministic port sets (PSID).

```text
                       CONTROL PLANE (DHCPv6 Softwire46)

  ISP DHCPv6 Server
         |
         |  IA_PD prefix + Option 94 (S46_CONT_MAPE: BR, BMR, PORTPARAMS)
         v
  +------------------+    dhcp6leasectl -l -m     +------------------+
  |  dhcp6leased(8)  | -------------------------> |     maped(8)     |
  +------------------+   (& LEASE_FILE trigger)   +------------------+
                                                           |
                     derives CE IPv6, shared IPv4,         | configures via
                     PSID port set, and GIF MTU            | maped-up
                                                           v
                 +---------------------------------------------------+
                 |  1. WAN IPv6 alias (CE_IPV6/128 on pppoe0)        |
                 |  2. gif(4) tunnel (CE_IPV6 <--> BR_IPV6)          |
                 |  3. pf(4) "mape" anchor (map-e-portset, max-mss)  |
                 |  4. IPv4 default route (-> gif0)                  |
                 +---------------------------------------------------+


                         DATA PLANE (Packet Encapsulation)

  +------------+      IPv4       +-----------------------------------+
  | LAN Client | --------------> | OpenBSD CE Router                 |
  | 192.168.x  |  src :ephemeral |                                   |
  +------------+                 |  pf(4) nat-to (gif0)              |
                                 |  map-e-portset offset/len/psid    |
                                 |    -> rewrites IPv4 src to        |
                                 |       MAPE_IPV4 : permitted_port  |
                                 |                                   |
                                 |  gif(4) encapsulates in IPv6      |
                                 |    -> outer src: CE_IPV6          |
                                 |    -> outer dst: BR_IPV6          |
                                 +-----------------+-----------------+
                                                   |
                                                   | IPv4-in-IPv6 (proto 4)
                                                   | over WAN (pppoe0)
                                                   v
                                 +-----------------------------------+
                                 | ISP MAP Border Relay (BR)         |
                                 |  - Decapsulates outer IPv6 header |
                                 |  - Forwards inner IPv4 packet     |
                                 |  - Routes return IPv4 traffic by  |
                                 |    dst IPv4 + dst port (PSID)     |
                                 +-----------------+-----------------+
                                                   |
                                                   | Native IPv4
                                                   v
                                           IPv4 Internet
```

### Provisioning and tunneling lifecycle

| Step | Component | Action | Output / State |
| :--- | :--- | :--- | :--- |
| **1. DHCPv6 request** | `dhcp6leased(8)` | Sends DHCPv6 Solicit/Request/Renew with `DHO_ORO` requesting Option 94 (`DHO_S46_CONT_MAPE`) when `request mape on <if>` is set in `dhcp6leased.conf(5)`. | Receives `IA_PD` delegated prefix and validated S46 BR, BMR rule, and optional port parameters; updates `/var/db/dhcp6leased/<if>`. |
| **2. Lease confirmation** | `maped(8)` | Detects a lease-file change or periodic health-check timer and queries `dhcp6leasectl -l -m <if>` over `/dev/dhcp6leased.sock`. | Confirms live `Bound`/`Renewing`/`Rebinding` state and establishes a monotonic expiry deadline from `lease-seconds:`. |
| **3. Parameter derivation** | `Maped.pm` (`derive_mape`) | Matches the delegated IPv6 prefix against the longest matching Basic Mapping Rule (BMR) and extracts the Embedded Address (EA) bits. | Computes `MAPE_IPV4`, `CE_IPV6` (`/64` prefix + `0000` + IPv4 hex + PSID hex), `BR_IPV6`, `PSID_OFFSET`, `PSID_LEN`, `PSID`, and `GIF_MTU` (`WAN_IF` MTU minus 40). |
| **4. Ownership & tunnel setup** | `maped-up` | Records ownership in `/var/db/maped/applied.conf`, adds `CE_IPV6/128` alias on `WAN_IF`, and configures `gif(4)` with outer IPv6 endpoints (`CE_IPV6` -> `BR_IPV6`) and inner IPv4 address (`MAPE_IPV4` -> `0.0.0.1`). | `gif0` is `UP` with the derived MTU (e.g., 1452 on a 1492-byte PPPoE link). |
| **5. PF anchor & routing** | `maped-up` & `pfctl(8)` | Validates and loads the `mape` `pf(4)` anchor: TCP SYN MSS clamping (`GIF_MTU - 40`), `nat-to ($GIF_IF)` (`map-e-portset` for shared allocations, or unrestricted when `PSID_LEN=0`), IPv6 proto-4 tunnel admission, and optional `rdr-to` inbound publishing rules; installs the IPv4 default route via `gif0`. | Outbound LAN and router IPv4 traffic is source-NATed (restricted to the assigned PSID port set when shared), encapsulated in IPv6 by `gif(4)`, and sent to the Border Relay. |
| **6. Health & withdrawal** | `maped(8)` & `maped-down` | Reconciles live kernel state (`ifconfig(8)`, `pfctl(8)`, `route(8)`) every 30s, atomically updates `/var/db/maped/status.json`, and tears down owned resources via `maped-down` if the lease is withdrawn or expires. | Self-heals configuration drift and prevents stale routes or unauthorized tunnels from persisting after lease expiry. |

## 1. Prepare the system

The [`pf(4)` MAP-E patch](https://github.com/toru-mano/openbsd-pf-map-e-ce) has
been publicly available since 2021 and adds MAP-E port-set translation to
`pf(4)`. Once the kernel and userland tools are patched, `maped(8)` configures
the `gif(4)` tunnel interface, `pf(4)` anchor, and IPv4 default route from the
live `dhcp6leased(8)` lease.

Base OpenBSD provides `OpenBSD::Pledge`, `OpenBSD::Unveil`, and `JSON::PP`, so
`maped(8)` requires no third-party packages at runtime. Install `git` to clone
this repository and create the tunnel interface:

```ksh
doas pkg_add git
printf 'create\nup\n' | doas tee /etc/hostname.gif0 >/dev/null
```

Use an OpenBSD 7.9 system and a clean `OPENBSD_7_9` (`7.9-stable`) CVS source
tree. To bootstrap an empty source tree, download and verify the source
archives:

```ksh
cd /tmp
ftp https://cdn.openbsd.org/pub/OpenBSD/7.9/src.tar.gz
ftp https://cdn.openbsd.org/pub/OpenBSD/7.9/sys.tar.gz
ftp https://cdn.openbsd.org/pub/OpenBSD/7.9/SHA256.sig
signify -C -p /etc/signify/openbsd-79-base.pub -x SHA256.sig src.tar.gz sys.tar.gz
cd /usr/src
doas tar xzf /tmp/src.tar.gz
doas tar xzf /tmp/sys.tar.gz
```

Update the clean tree to `7.9-stable`:

```ksh
cd /usr/src
cvs -q -d anoncvs@anoncvs.ca.openbsd.org:/cvs update -rOPENBSD_7_9 -Pd
```

> NOTE: Follow the [OpenBSD `-stable` build instructions](https://www.openbsd.org/stable.html)
> for source ownership and build-directory setup, and record the source
> revisions used for each build.

## 2. Patch the system

Clone the repository and apply the patches:

```ksh
doas mkdir -p /usr/local/src
cd /usr/local/src
doas git clone https://github.com/atmosx/openbsd-mape-ce
cd /usr/src
doas patch -p1 < /usr/local/src/openbsd-mape-ce/openbsd/patches/7.9/pf-map-e-ce/mape79.patch
doas patch -p1 < /usr/local/src/openbsd-mape-ce/openbsd/patches/7.9/dhcp6leased-mape-softwire46-openbsd79.patch
```

## 3. Build the kernel and userland tools

The `pf(4)` patch changes the kernel and userland PF ABI. A patched kernel must
be paired with rebuilt PF consumers, not just `pfctl(8)`: these include
`ftp-proxy(8)`, `tftp-proxy(8)`, `relayd(8)`, and `systat(1)`. Rebuild base
userland rather than assuming existing binaries remain compatible, and rebuild
any third-party PF consumers separately.

Build and install the kernel, then reboot:

```ksh
cd /usr/src/sys/arch/$(machine)/conf
doas config GENERIC.MP
cd ../compile/GENERIC.MP
doas make clean
doas make -j$(sysctl -n hw.ncpu)
doas make install
doas reboot
```

On the patched kernel, rebuild base userland using the standard release(8)
build procedure. This installs the matching headers and rebuilds all PF
consumers:

```ksh
cd /usr/src
doas make obj
doas make build
```

The build process can take a while on low-powered devices.

Update `/etc/pf.conf` to include `anchor "mape"` where MAP-E rules should be
evaluated. The `mape` anchor ruleset is managed by `maped(8)`. See the
[example `pf.conf`](examples/pf.conf) for a complete router configuration.

Before reconnecting the router, validate `/etc/pf.conf` with
`doas pfctl -nf /etc/pf.conf`, load the ruleset, and confirm that `pf(4)` is
enabled.

Enable the `mape` request in `/etc/dhcp6leased.conf`:

```ksh
request prefix delegation on pppoe0 for { em1/64 em2/64 em3/64 }
request mape on pppoe0 # enable MAP-E on this interface
```

Restart `dhcp6leased(8)` and verify that MAP-E parameters were received:

```ksh
doas rcctl restart dhcp6leased
doas dhcp6leasectl -l pppoe0

pppoe0 [Bound]
        IA_PD 0: 2a02:x:x:x::/56
        lease 7 days
        MAP-E
                BR: 2a02:x::406
                rule: flags 0 ea-len 14 80.x.x.0/24 2a02:x:x::/42
                portparams: offset 6 psid-len 0 psid 0
```

At this point the system has IPv6 connectivity, while IPv4 awaits tunnel
configuration. Install `maped(8)` to manage `gif0`:

```ksh
cd /usr/local/src/openbsd-mape-ce
doas make install
```

This installs `maped` in `/usr/local/sbin`, its helpers in
`/usr/local/libexec/maped`, `/etc/maped.conf`, `/etc/rc.d/maped`, and
`maped(8)` in `/usr/local/man/man8`.

Edit `/etc/maped.conf` and set `WAN_IF`, `LEASE_IF`, `LAN_NET`, `GIF_IF`,
`LEASE_FILE`, and `PF_ANCHOR_FILE` to match the local system.

Enable and start the `maped` service:

```ksh
doas rcctl enable maped
doas rcctl start maped
doas rcctl check maped
```

Inspect `/var/log/daemon`:

```text
grep maped /var/log/daemon

Oct  3 00:35:10 hermes maped[27676]: started; using /etc/maped.conf (restart to reload); watching /var/db/dhcp6leased/pppoe0; health check every 30s
Oct  3 00:35:10 hermes maped[27676]: applying current MAP-E provisioning
Oct  3 00:35:11 hermes maped[27676]: MAP-E reconfiguration complete
Oct  3 00:35:41 hermes maped[27676]: applying current MAP-E provisioning
```

Verify that `gif0` is configured:

```text
ifconfig gif0

gif0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1452
        index 68 priority 0 llprio 3
        encap: txprio payload rxprio payload
        groups: gif egress
        tunnel: inet6 2f02:586:x:x:x:: --> 2f02:586::x ttl 64 nodf ecn
        inet 5.6.7.8 --> 0.0.0.1 netmask 0xffffffff
```

See `maped(8)` for command-line options, configuration variables, files, and
helper paths.

## 4. Prometheus metrics

`metrics/mape-prometheus-metrics` exports MAP-E control-plane health, `pf(4)`
queue statistics, and `pfctl_exporter`-compatible metrics in Prometheus
textfile format (`doas make metrics-install`). See
[`metrics/README.md`](metrics/README.md) for `cron(8)` and `node_exporter`
setup, scrape configuration, the companion Grafana dashboard, and the full
metric list.

## 5. Allocation status and history

`maped(8)` writes `/var/db/maped/status.json` (or `$MAPED_STATE_DIR/status.json`
when configured) using base Perl's `JSON::PP`. It includes `last-update`, all
current port ranges, and a persistent `record` timeline of the MAP-E IPv4
address, CE and BR IPv6 addresses, delegated prefix, and PSID changes. The file
is updated atomically during reconciliation and retained across restarts; it is
for reporting only, not lease authorization.

See [JSON status and history](docs/status-json.md) for the schema, permissions,
freshness requirements, no-extra-package examples, and test procedure.

## 6. Optional inbound IPv4 publishing

Set `MAPED_PUBLISH_FILE` in `/etc/maped.conf` to a service JSON file to publish
router-local TCP/UDP services using currently allocated MAP-E ports.
Assignments follow lease changes; healthy renewals retain valid ports without
reloading `pf(4)`. Publishing is disabled by default. See
[setup and limitations](docs/inbound-publishing.md) and the
[JSON service example](examples/maped-publish.json). Successful endpoints and
persistent change events are included in `status.json`.

## 7. Support

This is an experimental project. If you need assistance, feel free to send an
email; help is provided on a best-effort basis without warranty.
