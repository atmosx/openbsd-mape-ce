# OpenBSD MAP-E CE support

This repository contains a collection of patches and scripts to add **Customer Edge Mapping of Address and Port with Encapsulation**, widely known as MAP-E CE, support to [OpenBSD](https://www.openbsd.org/) 7.8.

## Status

This should be considered an experimental project. Don't rely on this implementation for production use.

## What is MAP-E CE?

![MAP-E graph](images/map-e-ce.jpeg)

MAP-E ([RFC7597](https://datatracker.ietf.org/doc/html/rfc7597)) is a somewhat new technology spreading fast among ISPs. The key characteristic is that it encapsulates IPv4 traffic into IPv6.

With MAP-E, multiple users share the same IPv4. On the bright side, users get real IPv6 routes.

> For reasons _unknown_ to me, my ISP doesn't assign static IPv6 addresses. It's a shame.

## 1. OpenBSD setup

The setup requires the following:

1. [openbsd-pf-map-e-ce](https://github.com/toru-mano/openbsd-pf-map-e-ce) adds NAT support to packet filter (pf).
2. `dhcp6leased` adds support for MAP-E CE to the system components.
3. Some basic networking configuration
4. A companion script to automate the network setup process

The [packet filter patch](https://github.com/toru-mano/openbsd-pf-map-e-ce) has been made publicly available since 2021. Applying the patch enables port mapping. Once the system's packet filter has been patched, use the Perl scripts to bring up a `gif0` interface.

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

Clone the repository to the system:

```ksh
cd /usr/local/src
doas git clone https://git.sr.ht/~atmosx/openbsd-mape-ce
cd openbsd-mape-ce
```

## 2. Patch the system

Now we have to apply the patches:

```ksh
cd /usr/src
doas patch -p0 < /usr/local/src/openbsd-mape-ce/patch/pf-map-e-ce/mape78.patch
doas patch -p0 < /usr/local/src/openbsd-mape-ce/patch/dhcp6leased-mape-softwire46-openbsd78.patch
```

> **NOTE**: Ignore the patches in the `split/` directory. These are an exact copy of `dhcp6leased-mape-softwire46-openbsd78.patch` split into scoped chunks.

Now let's rebuild the kernel and reboot:

```ksh
cd /usr/src/sys/arch/amd64/conf
doas config GENERIC.MP
cd ../compile/GENERIC.MP
doas make clean
doas make -j$(sysctl -n hw.ncpu)
doas make install
doas reboot
```

Now let's rebuild the userland tools:

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

Enable `mape` request in `/etc/dhcp6leased.conf`:

```ksh
request prefix delegation on pppoe0 for { em1/64 em2/64 em3/64 }
request mape on pppoe0 # enable MAPE on this interface
```

Then restart the daemon and check if MAP-E has been successfully enabled:

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

Now proceed by installing the `mape` Perl scripts:

```ksh
cd /usr/local/src/openbsd-mape-ce
doas make install
```

Adjust `/etc/mape.conf`. Make sure the following variables match your system's setup: `WAN_IF`, `LEASE_IF`, `LAN_NET`, `GIF_IF`, `LEASE_FILE`, and `PF_ANCHOR_FILE`.

Enable the `mape_watch` service:

```ksh
doas rcctl enable mape_watch
doas rcctl start mape_watch
doas rcctl check mape_watch
```

Check the `gif0` interface and packet filter `mape` anchor. You should see similar output:

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

## Helping & Testing

Help and testing are more than welcome! If you'd like to help with testing, feel free to send email, requests, questions, and patches to the project's mailing list: `~atmosx/openbsd-mape-ce@lists.sr.ht`

