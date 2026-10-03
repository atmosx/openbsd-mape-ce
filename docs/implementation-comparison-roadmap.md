# MAP-E implementation comparison and development roadmap

## Purpose

This report records ideas from OpenWrt and FreeBSD that could improve this
OpenBSD MAP-E CE implementation. It is a work plan, not a claim that the
proposed features or validation have been completed.

The principal recommendation is to strengthen **live packet validation,
provisioning-change behavior, and diagnostics**, while retaining the current
OpenBSD architecture: patched `dhcp6leased`, `maped`, `gif(4)`, and PF
`map-e-portset`.

No upstream binaries were built or exercised for this comparison. Findings
are based on source inspection. Suspected defects are identified separately
from demonstrated source behavior.

## Sources and reproducibility

### OpenWrt

The reviewed implementation is the `openwrt-24.10` branch. These URLs are
branch references, not immutable snapshots; pin a commit and record build
options before using its calculator as a test reference.

- [MAP package definition](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/network/ipv6/map/Makefile)
- [MAP protocol handler, `map.sh`](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/network/ipv6/map/files/map.sh)
- [Parameter calculator, `mapcalc.c`](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/network/ipv6/map/src/mapcalc.c)
- [DHCPv6 integration script](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/network/ipv6/odhcp6c/files/dhcpv6.script)
- [`odhcp6c` capabilities and exported softwire variables](https://github.com/openwrt/odhcp6c/blob/master/README.md)
- [OpenWrt MAP configuration documentation](https://openwrt.org/docs/guide-user/network/map)
- [MAP-E/fw4 compatibility discussion, issue #11972](https://github.com/openwrt/openwrt/issues/11972)

The issue documents compatibility concerns around the iptables-to-nftables
transition. It is not evidence that every current OpenWrt configuration is
broken, nor was a universal resolution verified during this review.

### FreeBSD

The original comparison used the 2021
[PF MAP-E introduction commit](https://github.com/pfsense/FreeBSD-src/commit/2aa21096c7349390f22aa5d06b373a575baed1b4).

The subsequent review pinned upstream `main` to
[`262fa4695d90207b9080f2cc5cb01eccf07fe243`](https://github.com/freebsd/freebsd-src/tree/262fa4695d90207b9080f2cc5cb01eccf07fe243),
whose recorded committer date is 2026-10-03. “Current FreeBSD” below refers
only to that snapshot, not all supported releases or future HEAD.

- [NAT and MAP-E allocators, `pf_lb.c`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/sys/netpfil/pf/pf_lb.c)
- [Rule grammar and validation, `parse.y`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/sbin/pfctl/parse.y)
- [Rule checksums, `pf_ioctl.c`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/sys/netpfil/pf/pf_ioctl.c)
- [Kernel Netlink representation, `pf_nl.c`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/sys/netpfil/pf/pf_nl.c)
- [Kernel nvlist conversion, `pf_nv.c`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/sys/netpfil/pf/pf_nv.c)
- [Userspace representation, `libpfctl.c`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/lib/libpfctl/libpfctl.c)
- [Live NAT tests, including MAP-E, `nat.sh`](https://github.com/freebsd/freebsd-src/blob/262fa4695d90207b9080f2cc5cb01eccf07fe243/tests/sys/netpfil/pf/nat.sh)

### Local baseline

- [OpenBSD validation evidence and deployment gate](../tests/OPENBSD79.md)
- [PF patch](../patch/pf-map-e-ce/mape79.patch)
- [PF patch provenance](../patch/pf-map-e-ce/REPO.md)
- [DHCPv6 patch](../patch/dhcp6leased-mape-softwire46-openbsd79.patch)
- [Daemon manual](../maped/maped.8)
- [Lease parsing and runtime checks](../maped/Maped.pm)
- [Parameter derivation](../maped/maped-derive)
- [Setup](../maped/maped-up) and [withdrawal](../maped/maped-down)
- [Extracted allocator tests](../tests/pf-nat-test.sh)
- [Extracted kernel-validator tests](../tests/pf-mape-validate-test.sh)

Local links describe the working repository and may change. Record the local
commit, patch checksums, kernel version, and userland versions with future
experimental results. The validation document remains authoritative about
which deployment checks have actually passed.

## Architecture comparison

| Responsibility | This project | OpenWrt | Reviewed FreeBSD PF code |
|---|---|---|---|
| DHCPv6 MAP provisioning | Patched `dhcp6leased` | `odhcp6c` and integration scripts | Outside the reviewed PF implementation |
| Parameter calculation | `maped-derive` | `mapcalc` | Configured PF port-set tuple |
| Lifecycle | `maped` and helpers | `netifd` and `map.sh` | Outside the reviewed PF implementation |
| Encapsulation | Fixed-endpoint `gif(4)` | Linux `ipip6` tunnel configured through netifd | Separate tunnel configuration required |
| Restricted NAT | PF `map-e-portset` | Generated firewall SNAT configuration for allowed ranges | PF `map-e-portset` |
| Translation mode | MAP-E only | MAP-E, MAP-T, LW4o6; MAP-T uses `nat46` | Reviewed change concerns NAT port selection |

OpenWrt's `map` is an official package, not the separate `cernet/MAP`
implementation. It installs a shell protocol backend and a compiled helper.
Installation, ISP provisioning, and firewall compatibility still affect whether
a particular deployment works automatically.

The local PF patch credits `toru-mano/openbsd-pf-map-e-ce`; this comparison does
not imply that the project is a FreeBSD or OpenWrt port.

## OpenWrt findings and opportunities

### O1. Differential testing against `mapcalc`

**Observed:** OpenWrt separates parameter calculation from network mutation.
`map.sh` invokes `mapcalc` with MAP rules and a tunnel-link context, then uses
the resulting addresses, port sets, and selected basic mapping rule (BMR).
The calculator uses OpenWrt libraries and interface information; it is not
necessarily a drop-in standalone function.

**Proposal:** build an optional test adapter that supplies equivalent rule and
prefix inputs to `mapcalc` and `maped-derive`.

Compare:

- Shared IPv4 address and CE IPv6 address.
- PSID and PSID length.
- Allowed port ranges and total permitted port count.
- Rule/prefix selection where both implementations support equivalent inputs.

Include zero-length PSIDs, minimum/maximum supported offsets and lengths,
prefix boundaries, explicit DHCP port parameters, and malformed inputs.
Distinguish valid zero-length-PSID provisioning from a PF rule syntax that
requires a nonzero PSID length: unrestricted NAT may be the appropriate output.

**Acceptance criteria:** a pinned reference build, reproducible input fixtures,
normalized output comparisons, and documented explanations for disagreements.
Resolve disagreements using RFC 7597/7598, not by assuming OpenWrt is correct.
Keep this a development dependency, not a production dependency. Check licensing
before copying implementation code; comparing outputs avoids needing to import
OpenWrt's GPL implementation into the local codebase.

### O2. Supported read-only configuration diagnostics

**Observed:** OpenWrt writes the input rule and calculated data to
`/tmp/map-$cfg.rules`. Locally, derivation and application are already separate,
and `Maped.pm` already checks runtime mismatches.

**Proposal:** expose a supported diagnostic interface rather than requiring
operators to interpret internal cache files. A command name and output schema
remain to be designed.

Report:

- Selected delegated prefix and BMR, with the reason for selection.
- CE IPv6, shared IPv4, BR address, offset, PSID length, and PSID.
- Allowed ranges or a concise summary and permitted port count.
- Expected tunnel MTU and TCP MSS.
- Live lease validity, last successful confirmation, and stale/query-failure state.
- Expected versus observed tunnel, address, route, and PF configuration.

**Acceptance criteria:** read-only operation; no changes to interfaces, PF, or
ownership records; text output suitable for operators and a versioned
machine-readable form if automation needs it. Do not present a persisted lease
snapshot as proof that service is still authorized.

### O3. Stable failure categories

**Observed:** OpenWrt reports protocol errors such as `INVALID_MAP_RULE`,
`NO_MATCHING_PD`, and `UNSUPPORTED_TYPE`.

**Proposal:** add stable categories alongside local human-readable diagnostics.
Possible categories include `NO_MATCHING_PD`, `AMBIGUOUS_PD`, `LEASE_EXPIRED`,
`BR_ROUTE_WRONG_INTERFACE`, `PF_CONFIGURATION_FAILED`, and `RUNTIME_DRIFT`.
These are proposed names, not existing API commitments.

**Acceptance criteria:** tests assert categories independently of prose; logs
retain useful context; metrics distinguish provisioning, application, and
runtime-health failures. Integrate with existing logging/metrics rather than
creating a second reporting system.

### O4. Explicit forwarding-rule scope

**Observed:** OpenWrt's MAP-E backend passes Forwarding Mapping Rules (FMRs) to
the tunnel layer. The local fixed-BR `gif(4)` design is oriented toward
hub-and-spoke forwarding.

FMR-based direct CE-to-CE forwarding needs destination-address/port-aware MAP
forwarding. Adding ordinary routes to a fixed-endpoint tunnel is not enough.

**Proposal:** first document the supported topology, report provisioned FMRs,
and define how unsupported rules are handled. Implement a new forwarding path
only if deployments require it.

**Standards caveat:** RFC 7597 permits deployments with no FMRs, but requires CE
implementations to support both rule types. Successful operation on a
hub-and-spoke ISP is narrower than full RFC functionality.

**Acceptance criteria:** explicit scope documentation and tests for leases that
contain forwarding rules; no silent claim of full FMR support.

## FreeBSD findings and opportunities

### F1. Live receiver-enforced port-set tests

**Observed:** current `nat.sh` contains `map_e_compat` and `map_e_pass`, covering
legacy `nat ... ->` and newer `pass ... nat-to` syntax. The original standalone
`map_e.sh` has been incorporated into this test file.

The fixture uses VNET jails to form:

```text
client -> PF NAT router -> TCP echo server
```

The receiver permits only these source ports for `map-e-portset 2/12/0x342`:

```text
19720-19723
36104-36107
52488-52491
```

The tuple gives three blocks of four ports, or 12 permitted ports. A receiver
firewall independently rejects traffic translated outside the assigned set.
The two MAP-E tests perform 12 sequential TCP attempts; they are not a
controlled exhaustion proof and do not cover MAP-E UDP or ICMP.

**Proposal:** reproduce the topology with isolated OpenBSD VMs or a dedicated
lab. Test PF without a MAP-E tunnel first, then add a separate tunnel/BR test.
Use the actual generated anchor/rule path as well as a minimal direct PF rule.

**Acceptance criteria:** patched kernel and matching userland; receiver-side
packet captures; successful return traffic; port membership verified for TCP
and UDP, identifier membership for ICMP echo. Confirm the fixture detects an
intentionally incorrect NAT configuration. Do not run destructive setup on the
operator's normal network.

### F2. Controlled exhaustion and recovery

**Proposal:** extend the 12-port fixture by holding 12 distinct TCP connections
open to the same remote address and port. Verify allocation of all permitted
translated ports, failure of an additional flow without out-of-set allocation,
and recovery after controlled state removal.

The fixed remote tuple matters: NAT may reuse a translated source port for
different remote endpoints. Avoid conflating socket closure with immediate PF
state expiry. Add a UDP variant with explicit timeout/state management.

**Acceptance criteria:** packet and PF-state evidence, bounded timeouts,
repeatable teardown, and no reliance on allocator randomness to reach the
exhausted condition. Preserve the existing extracted allocator tests; live
coverage complements rather than replaces them.

### F3. Suspected ICMP range regression in current FreeBSD

**Observed source path:** `pf_get_mape_sport()` supplies restricted ranges to
`pf_get_sport()`, but the latter unconditionally sets `low = 1` and
`high = 65535` for IPv4 ICMP echo. By inspection, this appears capable of
allocating an echo identifier outside the MAP-E set.

**Status:** suspected upstream defect, not reproduced in a running kernel.
Do not cite this report as proof of affected release behavior. A minimal
packet reproduction and revision history investigation are needed before an
upstream bug report.

The local patch already guards the ordinary echo-range override with
`!r->nat.mape.offset`, and the extracted allocator regression covers MAP-E echo
ranges. Retain that fix and add live verification under F1. Include ordinary
NAT as a control, and separately exercise ICMP errors and PMTU-related traffic;
non-echo errors are not simply another identifier-allocation case.

### F4. Existing state and provisioning changes

**Observed:** current FreeBSD's allocator integrates UDP endpoint-independent
mapping and can return an existing mapping before searching a new range.
This demonstrates an important interaction to audit; it does not establish a
FreeBSD mapping-invalidation bug.

**Proposal:** define and test local state policy when the shared IPv4 address,
PSID, or delegated prefix changes. PF rule replacement must not be assumed to
invalidate existing NAT state automatically.

Test sequence:

1. Establish TCP and UDP flows under provisioning A.
2. Change to provisioning B with a different PSID and/or shared address.
3. Reconcile the tunnel, alias, route, and anchor.
4. Send on existing flows and establish new ones.
5. Capture translated packets and inspect state retention/removal.
6. Repeat for withdrawal, expiry, restart, and unchanged renewal.

**Acceptance criteria:** documented policy; no use of a withdrawn port set after
the defined transition boundary; unchanged renewals do not unnecessarily
interrupt service; unrelated PF states survive. Investigate targeted state
ownership/selection before adding cleanup. A global state flush is not an
acceptable default.

Endpoint-independent mapping itself is not proposed for immediate import.
Its compatibility and state-lifetime implications require a separate design.

### F5. Rule round-trip and kernel-boundary validation

**Observed:** FreeBSD carries MAP fields through Netlink and nvlist
representations, userspace libraries, and rule display. This is integration
work beyond the allocation algorithm.

**Proposal:** test OpenBSD's native interfaces end to end:

```text
parse -> load rule -> kernel representation -> retrieve/display -> compare
```

Check offset, length, and PSID after loading and after anchor reloads. Confirm
ordinary NAT does not inherit MAP parameters. Exercise invalid kernel imports
through a controlled test harness, not only through `pfctl` parsing.

**Acceptance criteria:** actual kernel round-trip tests and bounded negative
cases; no undefined shifts or invalid tuple acceptance. Existing parser and
extracted validator tests remain useful but do not prove the live ioctl path.
Do not copy FreeBSD's Netlink or libpfctl architecture into OpenBSD.

### F6. Ruleset checksum and `pfsync` audit

**Observed:** current FreeBSD hashes `mape.offset`, `mape.psidlen`, and
`mape.psid` explicitly, using canonical byte order for the PSID. The local
`pf_hash_rule()` in `src/sys/net/pf_ioctl.c` does not include these MAP fields.

**Status:** audit opportunity, not a demonstrated OpenBSD defect. The local
hash also omits other translation details, and checksum/anchor semantics must
be understood before changing it.

Questions to resolve:

- Should a PSID-only change alter the relevant ruleset checksum?
- How is the `mape` anchor represented in checksum comparisons?
- What do mismatched rulesets mean for synchronized state association?
- Is HA MAP-E operation supported, unsupported, or merely untested?
- Can both routers legitimately use the same delegated prefix/CE identity?

**Acceptance criteria:** documented intended semantics and focused tests. If
hash changes are justified, hash explicit fields, not padded structures.
Do not imply that matching checksums alone establish correct HA provisioning.

### F7. Keep local allocator and parser safeguards

The reviewed FreeBSD snapshot retains several original implementation details:

- Starting block selection uses `arc4random() & ahigh`, then changes zero to
  one, giving block one extra probability.
- Parser PSID validation checks the 16-bit range rather than requiring the
  value to fit its declared PSID width; the allocator masks the value.
- The incompatible custom-port-range check combines changed endpoints with
  `&&`, leaving one-endpoint changes as important regression cases.
- The outer MAP-E search receives a generic allocation failure rather than
  the local distinction between exhaustion and address-selection failure.

Retain the local uniform starting-block selection, width validation,
one-endpoint parser regressions, and immediate stop on address-selection
failure. Current upstream code is a comparison point, not automatically a
better replacement.

## Prioritized work backlog

All items below are proposals and remain unchecked by this report.

| Priority | Work item | References | Completion evidence |
|---|---|---|---|
| P0 | Build isolated patched-kernel PF packet fixture | F1, F3 | TCP/UDP/echo captures, valid return traffic, negative control |
| P0 | Define and verify state policy on provisioning change | F4 | Changed PSID/address, withdrawal, and unchanged-renewal results |
| P1 | Add controlled exhaustion and recovery | F2 | Full 12-port occupancy, bounded failure, recovery |
| P1 | Add live rule round-trip and import validation | F5 | Retrieved tuples match; malformed imports rejected |
| P1 | Add optional `mapcalc` differential suite | O1 | Pinned build, equivalent fixtures, RFC-resolved discrepancies |
| P1 | Expose read-only plan and runtime diagnosis | O2, O3 | Stable categories and no-mutation tests |
| P2 | Document and test FMR/topology limitations | O4 | Explicit behavior for provisioned forwarding rules |
| P2 | Audit checksum and HA assumptions | F6 | Written semantic analysis and targeted regressions |

### Experiment record template

For each completed task, record:

- Local commit and patch checksums.
- Upstream reference commit and build configuration, if used.
- Kernel/userland versions and whether the patched kernel was actually booted.
- Topology, interface ownership, addressing, rules, and cleanup procedure.
- Fixture inputs and expected results.
- Commands, exit statuses, packet captures, and relevant PF states/counters.
- Negative control and observed failure mode.
- Result classification: passed, failed, inconclusive, or source inspection only.
- Remaining limitations and any upstream issue/report link.

Update [the deployment gate](../tests/OPENBSD79.md) only when its actual live
requirements have been satisfied. Compilation, stubbed tests, and source
comparison are not substitutes for packet-path evidence.

## Architectural boundaries to preserve

- Keep the direct PF port-set constraint; do not replace it with a large list
  of generated NAT rules merely to resemble OpenWrt.
- Keep strict configuration parsing rather than copying shell `eval` patterns.
- Preserve live lease confirmation, monotonic expiry, ownership-aware cleanup,
  frozen helper configuration, and runtime reconciliation.
- Do not introduce a generic network manager or a production `mapcalc`
  dependency for these improvements.
- Treat MAP-T, full FMR forwarding, endpoint-independent NAT changes, and HA
  provisioning as separate designs, not incidental additions to this roadmap.

## Standards references

- [RFC 7597: MAP-E](https://www.rfc-editor.org/rfc/rfc7597.html), especially
  mapping rules, port mapping, forwarding, and NAT requirements.
- [RFC 7598: DHCPv6 softwire provisioning](https://www.rfc-editor.org/rfc/rfc7598.html).
- [RFC 4787: UDP NAT behavior](https://www.rfc-editor.org/rfc/rfc4787.html).
- [RFC 5382: TCP NAT behavior](https://www.rfc-editor.org/rfc/rfc5382.html).
- [RFC 5508: ICMP NAT behavior](https://www.rfc-editor.org/rfc/rfc5508.html).

Local copies of these RFCs are also available in `docs/`.
