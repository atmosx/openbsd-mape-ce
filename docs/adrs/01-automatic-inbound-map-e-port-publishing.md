# ADR: Automatic inbound MAP-E port publishing

## Issue

MAP-E gives this router a restricted set of external IPv4 ports that as per [rfc7597, section 8.1](../rfc/rfc7597.txt) there is a direct port mapping between BR port number and CE port number. That allows to open IPv4 ports to the world wide web.

```
                       MAP-E: inbound IPv4 port reachability

      Internet
         |
         |  IPv4 packet to shared public address :3032
         v
   +-------------------------+
   | ISP MAP Border Relay    |
   |                         |
   | Uses IPv4 address +     |
   | destination port/PSID   |
   | to identify the CE      |
   +------------+------------+
                |
                | IPv4-in-IPv6 tunnel
                | destination port remains 3032
                v
   +-------------------------+
   | MAP-E Customer Edge     |
   |                         |
   | Assigned public IPv4    |
   | address + restricted    |
   | port set (includes 3032)|
   |                         |
   | NAPT/port-forward rule  |
   | :3032 -> LAN service    |
   +------------+------------+
                |
                v
          Internal server
          e.g. 192.168.1.10:80


        ISP may change the CE's IPv6 address, public IPv4 address,
        or assigned port set over time
                            |
                            v
          Previously configured static port mapping may
          stop working if its address or port is no longer assigned
 ```


The problem is that the ISP can change the IPv6, IPv4 and port-range allocation dynamically. This means that any static setup port-mapping is prone to failure over time.


## Proposal

**Proposed:** Add optional inbound publishing to `maped`. An administrator supplies a JSON service file through `MAPED_PUBLISH_FILE` in `/etc/maped.conf`; without that setting, publishing is disabled. Initially support router-local IPv4 targets at `127.0.0.1`, with one TCP or UDP endpoint per service.

Optional administrator-managed PF source tables restrict who can connect; absent a table, the generated rule uses `from any`.

On each confirmed allocation, `maped` retains valid previous assignments, then assigns remaining services the lowest free permitted external port at or above 1024, in service-name order, separately for TCP and UDP. If all services cannot be assigned, reject the candidate rather than publish only some. Saved assignments are preferences, never proof of lease authorization.

Extend the existing reconciliation path and `mape` PF anchor rather than adding a second firewall writer. Validate and explicitly load the complete anchor, including existing NAT, MSS, and tunnel rules. Publish structured endpoints and persistent change events in `status.json` only after successful application.  Withdraw redirects when the allocation expires or is withdrawn. Do not alter the parent PF ruleset or disable PF.

## Status

Review

## Assumptions

- The patched PF, `maped`, its managed `mape` anchor, and the existing private [status JSON](../status-json.md) are available.
- The live DHCPv6 MAP-E lease, not saved assignments or status, determines which IPv4 address and ports are authorized.
- `maped` config is read at startup; edits to the service file require a restart. Parsing can use base Perl's `JSON::PP`.

## Constraints

- Reject malformed or unreadable configured service files and invalid fields; do not fall back to unrestricted rules.
- Do not advertise a failed candidate or retain an old endpoint after its allocation is no longer valid. Preserve unchanged sessions and avoid needless PF reloads on healthy renewals.
- A generated `pass in quick` rule can admit traffic from any source if no table is configured. Earlier `block quick` rules can prevent the anchor from matching. Administrators must position the anchor, manage any source tables, and remove competing manual redirect rules.
- Port assignment prevents collisions among managed inbound services, **not** with outbound NAT port selection. An assigned port and a loaded rule do not prove ISP reachability or a listening service.

## Positions

1. Continue manual port selection and PF rules: simpler code, but fragile across allocation changes and difficult to report reliably.
2. Run a separate publisher that observes `status.json` and edits PF: separates processes, but introduces two writers and treats reporting state as authority.
3. **Proposed:** integrate assignment, PF rules, and reporting into `maped` reconciliation, which already owns the live allocation and anchor.


## Related decisions

None.

## Related requirements

Configure a router-local service once; assign only currently permitted MAP-E ports; keep PF rules aligned with the live allocation; expose successfully configured endpoints and changes without promising reachability.

## Related artifacts

[`maped-up`](../../maped/maped-up), [`maped` manual](../../maped/maped.8), [status JSON](../status-json.md), and [example PF rules](../../examples/pf.conf).
