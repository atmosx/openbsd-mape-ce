# OpenBSD MAP-E CE support

This repository contains a collection of patches and scripts to add **Customer Edge Mapping of Address and Port with Encapsulation**, widely known as MAP-E CE ([RFC7597](https://datatracker.ietf.org/doc/html/rfc7597)), support to [OpenBSD](https://www.openbsd.org/) 7.8.

[![builds.sr.ht status](https://builds.sr.ht/~atmosx/openbsd-mape-ce/commits/main/.build.yml.svg)](https://builds.sr.ht/~atmosx/openbsd-mape-ce/commits/main/.build.yml?)

## Status

This is an experimental project. Do not rely on this implementation for production use.

## 1. Setup

The following are required:

1. [openbsd-pf-map-e-ce](https://github.com/toru-mano/openbsd-pf-map-e-ce) adds MAP-E NAT support to `pf(4)`.
2. `dhcp6leased(8)` adds support for MAP-E CE to the base system.
3. Basic networking configuration.
4. A companion application to automate the network setup process.

The [packet filter patch](https://github.com/toru-mano/openbsd-pf-map-e-ce) has been publicly available since 2021. Applying the patch enables port mapping in MAP-E. Once `pf(4)` has been patched, use the Perl application to bring up a `gif(4)` interface.

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
cd /usr
doas tar xzf /tmp/sys.tar.gz
```

## 2. Patch the system

Clone the repository and apply the patches:

```ksh
cd /usr/local/src
doas git clone https://git.sr.ht/~atmosx/openbsd-mape-ce
cd openbsd-mape-ce
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

## Help and testing

Reports, questions and patches are welcome on the project's mailing list: `~atmosx/openbsd-mape-ce@lists.sr.ht`.
