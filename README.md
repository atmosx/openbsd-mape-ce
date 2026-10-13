# OpenBSD MAP-E CE support

This repository contains patches and utilities to add Customer Edge Mapping of
Address and Port with Encapsulation (MAP-E CE,
[RFC 7597](https://datatracker.ietf.org/doc/html/rfc7597)) support to
[OpenBSD](https://www.openbsd.org/) 7.9.

## Status

This is an experimental project.

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
doas patch -p1 < /usr/local/src/openbsd-mape-ce/patch/pf-map-e-ce/mape79.patch
doas patch -p1 < /usr/local/src/openbsd-mape-ce/patch/dhcp6leased-mape-softwire46-openbsd79.patch
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

The `metrics/mape-prometheus-metrics` script writes MAP-E and `pf(4)` metrics in
Prometheus textfile format. Install it with:

```ksh
cd /usr/local/src/openbsd-mape-ce
doas make metrics-install
doas install -d -o root -g wheel -m 755 /var/prometheus/textfile
```

Run it from `cron(8)` so the metrics file is refreshed regularly:

```cron
* * * * * /usr/local/sbin/mape-prometheus-metrics >/dev/null 2>&1
```

Serve the generated file with the `node_exporter` textfile collector:

```ksh
node_exporter --collector.textfile.directory=/var/prometheus/textfile
```

Then scrape the router's `node_exporter` from Prometheus. See
[`metrics/README.md`](metrics/README.md) for an example scrape configuration,
`httpd(8)` fallback serving, the companion Grafana dashboard, and the full
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
