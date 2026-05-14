# OpenBSD MAP-E CE

This repository contains a collection of scripts and guides to enable MAP-E support to [OpenBSD](https://www.openbsd.org/).

## Official Status in OpenBSD 7.8 or earlier

OpenBSD doesn't support MAP-E out of the box at this point.

## What works right now?

A [packet filter patch](https://github.com/toru-mano/openbsd-pf-map-e-ce) has been made publicly available since 2021. Applying the patch allows enables the port-mapping. Once the system's packet filter has been patched, use the perl scripts to bring up a `gif0` interface.

## Step by Step Howto

todo

# About MAP-E

## Introduction to MAP-E

MAP-E, described in detailed in [RFC7597](https://datatracker.ietf.org/doc/html/rfc7597), is a common technology adopted by ISPs adopting IPv6. The protocol encapsulates IPv4 traffic into IPv6.

<iframe width="560" height="315" src="https://www.youtube.com/embed/CEvt3yxLyww?si=Z2xKp43CXLs3oMvQ" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
