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

# Provisioning snapshots

The daemon and derivation helper share a lease parser. Port parameters stay
attached to their rule, and the BMR is selected by longest IPv6-prefix match
(RFC 7597 §5 and RFC 7598 §4.1). Omitted port parameters default to offset 6
and an EA-derived PSID. A PD must contain the IPv4 suffix bits; if it omits
PSID bits, an explicit full-length PORTPARAMS PSID is required and used in
both NAT and the CE IPv6 identifier. Conflicting known EA bits are rejected.
Equal-length ambiguous rules and multiple matching end-user prefixes are
rejected rather than silently choosing the last one.
This remains a single-domain, hub-and-spoke implementation, not mesh support.

`maped-up` receives a private snapshot from the daemon; derivation does not
reread changing lease sources during that operation. Standalone derivation
can read a lease file or control output, but never merges their fields.

# Live lease authority and withdrawal

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
prevents concurrent instances using the same directory. On OpenBSD, install the
`OpenBSD::Pledge` and `OpenBSD::Unveil` Perl modules before starting maped:
missing sandbox support is fatal rather than silently running unsandboxed.

The daemon and all helpers accept literal shell-style configuration values.
Quotes and comments are supported; expansions and shell commands are rejected.
Restart to reload configuration. Each operation uses a frozen configuration.

# Runtime reconciliation

Health checks compare tunnel endpoints, IPv4 addressing, the CE address,
tunnel MTU, NAT port-set parameters, TCP MSS and the IPv4 default route against
the frozen desired configuration. Equivalent IPv6 spellings compare equally.
Automatic MTU follows changes to the local WAN MTU; explicit overrides remain
fixed. This is local state repair, not kernel tunnel PMTU discovery. While the
service is active, maped expects the IPv4 default route to use its GIF tunnel.
