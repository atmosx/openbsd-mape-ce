# OpenBSD MAP-E CE support

This repository contains a collection of patches and scripts to add **Customer Edge Mapping of Address and Port with Encapsulation**, widely known as MAP-E CE ([RFC7597](https://datatracker.ietf.org/doc/html/rfc7597)), support to [OpenBSD](https://www.openbsd.org/) 7.8.

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

Download and extract the source code:

```ksh
cd /tmp
ftp https://cdn.openbsd.org/pub/OpenBSD/7.8/src.tar.gz
ftp https://cdn.openbsd.org/pub/OpenBSD/7.8/sys.tar.gz
cd /usr/src
doas tar xzf /tmp/src.tar.gz
doas tar xzf /tmp/sys.tar.gz
```

## 2. Patch the system

Clone the repository and apply the patches:

```ksh
doas mkdir /usr/local/src
cd /usr/local/src
doas git clone https://github.com/atmosx/openbsd-mape-ce
cd /usr/src
doas patch -p0 < /usr/local/src/openbsd-mape-ce/patch/pf-map-e-ce/mape78.patch
doas patch -p0 < /usr/local/src/openbsd-mape-ce/patch/dhcp6leased-mape-softwire46-openbsd78.patch
```

> **NOTE**: Ignore the patches in the `split/` directory. These are an exact copy of `dhcp6leased-mape-softwire46-openbsd78.patch` split into scoped chunks.

Rebuild the kernel and reboot:

```ksh
cd /usr/src/sys/arch/amd64/conf
doas config GENERIC.MP
cd ../compile/GENERIC.MP
doas make clean
doas make -j$(sysctl -n hw.ncpu)
doas make install
doas reboot
```

Rebuild the userland tools:

```ksh
cd /usr/src/sbin/pfctl
doas make obj
doas make
doas make install

cd /usr/src/sbin/dhcp6leased
doas make obj
doas make
doas make install

cd /usr/src/usr.sbin/dhcp6leasectl
doas make obj
doas make
doas make install
```

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
pass in quick on gif0 inet from any to (gif0) flags S/SA
```
