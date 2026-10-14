# Tunnel MTU and TCP MSS

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

See `maped(8)` for BMR selection, parameter derivation, live lease
confirmation, ownership-aware withdrawal, and runtime reconciliation.
