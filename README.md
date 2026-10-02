# OpenBSD MAP-E CE support

This repository contains a collection of patches and scripts to add **Customer Edge Mapping of Address and Port with Encapsulation**, widely known as MAP-E CE ([RFC7597](https://datatracker.ietf.org/doc/html/rfc7597)), support to [OpenBSD](https://www.openbsd.org/) 7.9.

## Status

This is an experimental project.

## 1. Setup

The following are required:

1. [openbsd-pf-map-e-ce](https://github.com/toru-mano/openbsd-pf-map-e-ce) adds MAP-E NAT support to `pf(4)`.
2. `dhcp6leased(8)` adds support for MAP-E CE to the base system.
3. Basic networking configuration.
4. A companion application to automate the network setup process.

The [packet filter patch](https://github.com/toru-mano/openbsd-pf-map-e-ce) has been publicly available since 2021. Applying the patch enables port mapping. Once `pf(4)` has been patched, use the Perl application to bring up a `gif(4)` interface.

Install the following packages and create the interface:

```ksh
doas pkg_add git p5-IO-KQueue
echo 'create\nup' > /etc/hostname.gif0
```

Use an OpenBSD 7.9 system and a clean `OPENBSD_7_9` (7.9-stable) CVS source tree. Do not mix release branches or apply these patches over an existing MAP-E patch. If `/usr/src` is already populated, preserve any local changes before updating it.

To bootstrap an empty source tree, download and verify the source archives:

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

Update the clean tree to 7.9-stable using your configured CVS mirror:

```ksh
cd /usr/src
cvs -q -d anoncvs@anoncvs.ca.openbsd.org:/cvs update -rOPENBSD_7_9 -Pd
```

Follow the [OpenBSD stable build instructions](https://www.openbsd.org/stable.html) for source ownership and build-directory setup. Record the source revisions used for each build; stable is a moving branch.

## 2. Patch the system

Clone the repository and apply the patches:

```ksh
doas mkdir /usr/local/src
cd /usr/local/src
doas git clone https://github.com/atmosx/openbsd-mape-ce
cd /usr/src
doas patch -p1 < /usr/local/src/openbsd-mape-ce/patch/pf-map-e-ce/mape79.patch
doas patch -p1 < /usr/local/src/openbsd-mape-ce/patch/dhcp6leased-mape-softwire46-openbsd79.patch
```

> **NOTE**: Ignore the patches in the `split/` directory. These are an exact copy of the original OpenBSD 7.8 patch split into scoped chunks. For 7.9, use only the two patch files above.

The PF patch changes the kernel/userland PF ABI. A patched kernel must be paired with rebuilt PF consumers, not just `pfctl`: these include `ftp-proxy`, `tftp-proxy`, `relayd`, and `systat`. Rebuild base userland rather than assuming existing binaries remain compatible. Rebuild any third-party PF consumers separately.

Perform installation during a maintenance window with console access. Do not rely on SSH surviving the transition: the old `pfctl` may fail to load the firewall on the first patched boot. Keep the router isolated from untrusted networks until the matching userland is installed and PF rules are verified. Back up the kernel, userland, and configuration together; a VM snapshot or full system backup is preferable to a kernel-only rollback. Binary kernel updates can replace the custom kernel and must not be applied without coordinating the patched build.

Rebuild the kernel and reboot:

```ksh
cd /usr/src/sys/arch/$(machine)/conf
doas config GENERIC.MP
cd ../compile/GENERIC.MP
doas make clean
doas make -j$(sysctl -n hw.ncpu)
doas make install
doas reboot
```

On the patched kernel, rebuild base userland using the standard build target. This installs the matching headers and rebuilds PF consumers:

```ksh
cd /usr/src
doas make obj
doas make build
```

Before reconnecting the router, verify `pfctl -nf /etc/pf.conf`, load the intended rules, and confirm PF is enabled and enforcing them. A kernel build alone is not a deployment acceptance test. See [the 7.9 validation checklist](tests/OPENBSD79.md).

Enable the `mape` request in `/etc/dhcp6leased.conf`:

```ksh
request prefix delegation on pppoe0 for { em1/64 em2/64 em3/64 }
request mape on pppoe0 # enable MAPE on this interface
```

Restart `dhcp6leased(8)` and verify that MAP-E has been enabled:

```ksh
rcctl restart dhcp6leased
dhcp6leasectl -l pppoe0

pppoe0 [Bound]
        IA_PD 0: 2a02:x:x:x::/56
        lease 7 days
        MAP-E
                BR: 2a02:x::406
                rule: flags 0 ea-len 14 80.x.x.0/24 2a02:x:x::/42
                portparams: offset 6 psid-len 0 psid 0
```

Install `maped`:

```ksh
cd /usr/local/src/openbsd-mape-ce
doas make install
```

This installs `maped` in `/usr/local/sbin` and its helpers in `/usr/local/libexec/maped`.

Edit `/etc/maped.conf`. Set `WAN_IF`, `LEASE_IF`, `LAN_NET`, `GIF_IF`, `LEASE_FILE`, and `PF_ANCHOR_FILE` to match the local system.

Enable the `maped` service:

```ksh
doas rcctl enable maped
doas rcctl start maped
doas rcctl check maped
```

See `maped(8)` for command-line options, files, and helper paths.

## Prometheus metrics

The `metrics/mape-prometheus-metrics` script writes MAP-E and PF metrics in
Prometheus textfile format. Install it with:

```ksh
cd /usr/local/src/openbsd-mape-ce
doas make metrics-install
doas install -d -o root -g wheel -m 755 /var/prometheus/textfile
```

Run it from cron so the metrics file is refreshed regularly:

```cron
* * * * * /usr/local/sbin/mape-prometheus-metrics >/dev/null 2>&1
```

Serve the generated file with the `node_exporter` textfile collector:

```ksh
node_exporter --collector.textfile.directory=/var/prometheus/textfile
```

Then scrape the router's `node_exporter` from Prometheus. See
`metrics/README.md` for example scrape config, httpd fallback serving, and the
full metric list.

Check the `gif0` interface and the `mape` anchor. The output should resemble:

```ksh
ifconfig gif0

gif0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1452
        index 11 priority 0 llprio 3
        encap: txprio payload rxprio payload
        groups: gif egress
        tunnel: inet6 2a02... --> 2a02... ttl 64 nodf ecn
        inet 87.x.x.x --> 0.0.0.1 netmask 0xffffffff

doas pfctl -a mape -sr

match out on gif0 inet from (gif0) to any nat-to (gif0) round-robin map-e-portset 6/6/63
match out on gif0 inet from 192.168.121.0/24 to any nat-to (gif0) round-robin map-e-portset 6/6/63
match out on gif0 inet from 192.168.122.0/24 to any nat-to (gif0) round-robin map-e-portset 6/6/63
match out on gif0 inet from 192.168.123.0/24 to any nat-to (gif0) round-robin map-e-portset 6/6/63
pass out quick on pppoe0 inet6 proto ipencap from 2a02... to 2a02...
pass in quick on pppoe0 inet6 proto ipencap from 2a02... to 2a02...
pass out quick on gif0 inet from (gif0) to any flags S/SA
```

The generated anchor does not permit unsolicited inbound IPv4 on `gif0`.
PF state admits replies; configure intended inbound services explicitly in
`pf.conf` (for example, a restricted VoIP peer and port range). Do not rely on
the MAP-E provider's port filtering as the router's firewall policy.

## Tunnel MTU and TCP MSS

`GIF_MTU="auto"` (also the default when omitted) selects the current
`WAN_IF` MTU minus the 40-byte outer IPv6 header when `maped-up` runs.
The IPv6 route to the border relay must use `WAN_IF`. A 1492-byte `pppoe0`
produces a 1452-byte `gif0`, matching the working Cosmote configuration.
Do not subtract PPPoE overhead a second time.

An existing `GIF_MTU="1452"` remains an explicit override. Use an override
if the downstream path needs a smaller value. Values outside OpenBSD's
GIF range (1280–8192) fail before interface changes; an automatic result
below 1280 is not silently rounded up. Health checks also recompute auto sizing after WAN-MTU changes. This is not
end-to-end tunnel PMTU discovery.

The generated PF anchor clamps outgoing IPv4 TCP SYN MSS to the selected
MTU minus 40 (1412 for MTU 1452). Remove any obsolete fixed clamp from the
parent ruleset when using the generated clamp. This helps TCP, not UDP.
Permit ICMPv6 Packet Too Big from intermediate routers as well as the BR;
the PF example includes `toobig`. Allowing these messages does not itself
implement tunnel ICMP error translation or kernel tunnel PMTU handling.

These settings follow the overhead and fragmentation guidance in RFC 7597
§§8.2–8.3, RFC 8200 §5, RFC 8201, and RFC 8900. Kernel tunnel PMTU/error
relaying remains outside this change's scope.

### Provisioning snapshots

The daemon and derivation helper share a lease parser. Port parameters stay
attached to their rule, and the BMR is selected by longest IPv6-prefix match
(RFC 7597 §5 and RFC 7598 §4.1). Omitted port parameters default to offset 6
and an EA-derived PSID. Equal-length ambiguous rules and multiple matching
end-user prefixes are rejected rather than silently choosing the last one.
This remains a single-domain, hub-and-spoke implementation, not mesh support.

`maped-up` receives a private snapshot from the daemon; derivation does not
reread changing lease sources during that operation. Standalone derivation
can read a lease file or control output, but never merges their fields.

### Live lease authority and withdrawal

Upgrade the patched `dhcp6leasectl` together with `maped`: the daemon now uses
`-l -m` and its exact `lease-seconds:` field, not the rounded lifetime display.
A persisted DHCP lease file is only a change-notification trigger, never
proof of an active lease. Bound, Renewing and Rebinding leases remain usable
until their confirmed expiry. Read failures do not extend that deadline.
On restart, a failed live query retires recorded configuration because the
new process has no remaining in-memory proof of validity.

`MAPED_STATE_DIR/applied.conf` records ownership before helper mutations.
Withdrawal and failed applies run `maped-down` against that record. The helper
preserves a default route on a different interface and a CE alias that existed
before maped configured service. Before applying changes, `maped-up` refuses to
replace an IPv4 default route unless it already points to its GIF interface
and configured peer. Remove or migrate another service's default route
explicitly before enabling MAP-E; maped does not save and restore it. Reserve
the GIF interface and `mape` PF anchor
for maped. Legacy `lease.state` files alone are not ownership records: obtain
a successful live configuration after upgrade before relying on auto-cleanup.
The state directory is root-owned and must not be group/world writable; a lock
prevents concurrent instances using the same directory.

The daemon and all helpers accept literal shell-style configuration values.
Quotes and comments are supported; expansions and shell commands are rejected.
Restart to reload configuration. Each operation uses a frozen configuration.

### Runtime reconciliation

Health checks compare tunnel endpoints, IPv4 addressing, the CE address,
tunnel MTU, NAT port-set parameters, TCP MSS and the IPv4 default route against
the frozen desired configuration. Equivalent IPv6 spellings compare equally.
Automatic MTU follows changes to the local WAN MTU; explicit overrides remain
fixed. This is local state repair, not kernel tunnel PMTU discovery. While the
service is active, maped expects the IPv4 default route to use its GIF tunnel.
