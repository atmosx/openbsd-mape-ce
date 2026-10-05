# Automatic inbound MAP-E publishing

Publishing is **disabled by default**. It opens selected router-local IPv4
services on ports from the current DHCPv6 MAP-E allocation. It does not request
ports from the ISP, configure the BR, publish DNS, or guarantee reachability.

## Configure

1. Copy [examples/maped-publish.json](../examples/maped-publish.json) to
   `/etc/maped-publish.json`, owned by root and not writable by other users.
   Review the example before enabling: `web` accepts **any IPv4 source**.
2. Add `MAPED_PUBLISH_FILE="/etc/maped-publish.json"` to `/etc/maped.conf`.
3. Ensure the target service listens on `127.0.0.1` at the configured port.
4. Position `anchor "mape"` in the administrator-managed parent PF ruleset.
   Earlier `block quick` rules can prevent the anchor from matching. Remove
   competing manual redirect/pass rules. The daemon neither edits the parent
   ruleset nor disables PF.
5. If using `source_table`, define and populate that PF table in the parent
   ruleset. For example, `table <admin4> persist` starts empty and admits no
   clients until you populate it. The daemon does not create or populate tables.
6. Restart with `doas rcctl restart maped`. Restart after changes to either
   configuration file. Inspect `doas pfctl -a mape -sr` and the private
   `/var/db/maped/status.json` (or your configured state directory).

The JSON object must contain exactly one field, `services`, an array. An empty
array publishes nothing. Each service accepts:

| Field | Required | Value |
|---|---|---|
| `name` | yes | Unique, case-sensitive name: letter followed by up to 47 letters, digits, `_` or `-` |
| `protocol` | yes | `tcp` or `udp` (one endpoint per service) |
| `target_address` | yes | Exactly `127.0.0.1`; LAN targets are not supported |
| `target_port` | yes | Port 1–65535 |
| `source_table` | no | PF table name without angle brackets: letter or `_`, then up to 30 letters, digits or `_` |

Unknown fields, duplicate service names, invalid values, malformed JSON and
unreadable configured files fail startup; there is no unrestricted fallback.
To publish both TCP and UDP, use separate service names. No external port is
configured in this file. The example is not a `status.json` document.

## Assignment and application

On each live confirmed allocation, valid saved port preferences are reserved
first. Remaining services receive the lowest free permitted port at or above
1024, in service-name order. TCP and UDP have independent port spaces. A saved
port is always checked against the **current** allocation, including after a
restart. If any service cannot be assigned, the whole candidate is rejected
and owned configuration is withdrawn; no subset is published.

For a shared allocation `6/8/42`, the first permitted ports are 1192–1195.
The example initially assigns `admin-ssh` port 1192 and `web` port 1193.
Traffic to the shared IPv4 address at port 1193 is forwarded by the BR without
changing that port, then redirected by the CE to `127.0.0.1:8080`.
See RFC 7597 sections 5.1 and 8.1.

The existing `mape` anchor contains the redirects alongside NAT, TCP MSS and
tunnel rules. Each inbound rule is `pass in quick`, matches the allocated IPv4
address, interface, protocol, external port and optional source table, and
uses `rdr-to` for the loopback target. The complete anchor is validated with
`pfctl -a mape -nf` and explicitly loaded with `pfctl -a mape -f`.
Healthy unchanged renewals do not reload PF or rebuild the tunnel. Changes and
failed applications may tear down owned networking as part of reconciliation.
Do not invoke `maped-up` directly to publish a service file: the candidate must
come from the daemon's live-lease reconciliation.

`published_endpoints` in [status.json](status-json.md) lists successfully applied
endpoints; `publish_events` preserves endpoint changes and withdrawals. A
failed candidate is never advertised. Lease expiry/withdrawal removes the
owned anchor rules and clears advertised endpoints. A temporary query failure
can retain previously confirmed endpoints until the existing deadline, with
status `degraded`. Consumers must check freshness and expiry as well as status.

Port assignment only avoids collisions **among managed inbound services**.
Outbound MAP-E NAT may select the same ports. An assigned endpoint does not
prove a listener exists, the ISP permits inbound traffic, or an external client
can connect. Test from an independent IPv4 network, including both allowed and
denied sources when using a table. Existing PF states are not an access-control
revocation mechanism; follow normal PF state-management procedures when
revoking a client's access.

## Validation

Run `make test` and `prove tests/maped-publish.t tests/maped-status.t
 tests/maped-daemon.t` for portable and mocked integration coverage.
On a patched OpenBSD router, also validate/load the generated anchor, exercise
TCP and UDP from an external network, test source-table restrictions, and
confirm withdrawal/reallocation. Portable mocks do not validate kernel PF
behavior, routing to loopback, or the ISP packet path.
