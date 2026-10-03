# Proposal: automatic inbound MAP-E port publishing

**Status:** proposed, not implemented. This document does not change PF or enable
inbound access.

## Goal

Configure local services once, then let `maped` select permitted external ports,
maintain PF redirects, and publish the resulting endpoints in `status.json`.

For the current `6/6/63` allocation, assume we want to publish port 22 and 583, an example is:

```text
87.202.58.210:2032/tcp -> 127.0.0.1:22
87.202.58.210:2033/tcp -> 127.0.0.1:583
```

MAP-E delivers packets to the customer without translating their destination
port. PF performs the local redirect. Neither an assigned port nor a loaded PF
rule proves that the ISP allows inbound traffic or that an application is
listening.

## Configuration

Opt in through `/etc/maped.conf`:

```sh
MAPED_PUBLISH_FILE='/etc/maped-publish.json'
```

Example service file, parsed using base Perl's `JSON::PP`:

```json
{
  "schema_version": 1,
  "services": [
    {
      "name": "ssh",
      "protocol": "tcp",
      "local_address": "127.0.0.1",
      "local_port": 22,
      "source_table": "admin4"
    },
    {
      "name": "service583",
      "protocol": "tcp",
      "local_address": "127.0.0.1",
      "local_port": 583
    }
  ]
}
```

Initial scope:

- Router-local IPv4 targets only; initially restrict targets to `127.0.0.1`.
  LAN forwarding requires separate routing and state tests.
- One `tcp` or `udp` endpoint per entry; use separate entries for both protocols.
- Unique stable service names, local ports 1–65535, and validated optional
  `source_table` names. Reject unknown configuration fields to catch typos.
- `source_table` limits a service to current members of an administrator-managed
  PF table. Omit it to generate `from any` (public to sources that can reach
  the anchor); no table is required. Table membership is dynamic and may be
  updated with `pfctl` without editing the service file or restarting `maped`.
  Membership changes affect new connections; existing PF states may persist.
  Changing which table a service references does require a configuration restart.
- Missing `MAPED_PUBLISH_FILE` disables publishing. An unreadable or malformed
  configured file is an error, not permission to publish unrestricted rules.
- Read and freeze configuration at startup, matching current `maped` semantics.
  Restart to adopt edits. No additional Perl packages or application restarts.

## External-port selection

Use the existing port-range calculator and the newly confirmed allocation:

1. Retain previous assignments that remain permitted and do not conflict.
2. Sort remaining services by name and assign the lowest free permitted port
   at or above 1024.
3. Allocate independently for TCP and UDP. Two services cannot share the same
   external protocol/port pair.
4. Reject an unsatisfiable candidate as a whole rather than partially publishing
   its services.

Saved assignments are preferences, not lease authorization. Address-only
changes should preserve ports when possible. Changing the local target need
not change the external port, but must update rules and mapping history.

This reserves ports **between managed inbound services only**. It does not
exclude them from PF's outbound NAT allocator. Test simultaneous inbound and
outbound use before deployment; exclusive reservation would require additional
allocator work and must not be promised implicitly.

## Dynamic PF updates

Integrate with the existing `maped` reconciliation and `mape` anchor. Do not add
a second process that reads status and independently edits the firewall.

Example generated rule for `ssh` with `source_table: "admin4"`:

```pf
pass in quick log on gif0 inet proto tcp \
    from <admin4> to 87.202.58.210 port 2032 \
    flags S/SA rdr-to 127.0.0.1 port 22 keep state
```

For a service without `source_table`, generate `from any` instead. UDP rules
omit TCP flags. Use the explicit derived public IPv4 address and validated
literals. `maped` configures forwarding, not the listening service.

Reconciliation sequence:

1. Confirm the live lease and derive addresses and port ranges.
2. Select service assignments and generate the **complete** candidate anchor,
   retaining existing NAT, MSS, and outer-tunnel rules.
3. Validate the candidate with the patched `pfctl` before mutations where
   practical. Publish an applying/unavailable status during a transition.
4. Replace the managed anchor file atomically and explicitly load it:

   ```sh
   pfctl -a mape -f /etc/pf.anchors/mape
   ```

5. After successful application, publish the configured endpoints and events.

**PF does not watch the file.** `maped` must invoke `pfctl`. Only the managed
anchor is replaced; the parent `/etc/pf.conf` is not rewritten or reloaded, and
PF remains enabled. An anchor transaction does not make the entire tunnel,
address, route, file, and firewall update one atomic operation.

Parent ruleset requirements:

- Keep `anchor "mape"` at a position reachable by intended inbound traffic.
- Earlier applicable `block quick` rules still take precedence.
- Provision and maintain referenced source tables in the appropriate PF anchor
  scope. Verify that table membership survives managed anchor reloads (or is
  restored before rules depending on it become active). `maped` must not
  overwrite administrator-managed members.
- Apply any additional source/abuse restrictions before the managed anchor;
  a `pass in quick` redirect with `from any` otherwise permits any source.
- Remove superseded manual IPv4 port-publishing rules to avoid two owners.
  Independent IPv6 SSH rules can remain.

Extend desired-state comparison and runtime health checks to cover every
managed redirect, so missing or altered rules trigger reconciliation.

## Changes, failures, and connection states

| Event | Required behavior |
|---|---|
| Healthy unchanged renewal | Preserve ports and existing sessions; no needless PF reload |
| IPv4 or port-set change | Recalculate, apply valid rules, then publish the new mapping |
| Service removed/disabled | Remove its redirect and record removal |
| Lease withdrawn/expired | Withdraw redirects and mark endpoints unavailable |
| Temporary query failure before confirmed expiry | Retain authorized rules; report degraded state |
| Validation/load failure | Report error; never advertise a failed candidate as configured |

On failure, old rules may be retained only while their allocation remains
confirmed and valid. Never retain an unauthorized old endpoint merely because
replacement failed. Track partial failures through existing ownership/cleanup
mechanisms; status must distinguish intended configuration from successful apply.

PF rule replacement does not automatically delete existing states. Before
implementation, determine a supported way to identify and remove states for
retired mappings (investigate dedicated labels and targeted state-kill APIs).
Preserve unrelated states and unchanged sessions. Do not use a global state
flush as a default solution.

## JSON status and notification interface

Extend [the existing status schema](status-json.md) with `published_services`:

```json
{
  "published_services": [
    {
      "name": "service583",
      "protocol": "tcp",
      "state": "configured",
      "remote": { "address": "87.202.58.210", "port": 2033 },
      "local": { "address": "127.0.0.1", "port": 583 }
    }
  ]
}
```

Use structured fields, not strings that applications must parse. A UI can render
`remote:2033 -> local:583`. Use `configured`, not `reachable`; on withdrawal,
mark the service unavailable and clear its current remote endpoint.

Persist a separate ordered `endpoint_record` array with:

- Monotonically increasing event `id`, service name, protocol, and UTC
  observation timestamp.
- Reason: initial configuration, mapping change, removal, withdrawal, or
  restoration.
- `previous` and `current` endpoint objects, each containing remote and local
  addresses/ports; null where no endpoint exists.

Append only actual successfully established mapping/lifecycle changes. No event
on a healthy no-op, and no configured event for a failed candidate. Preserve
history and IDs across restart. Reconcile persisted assignments against live
provisioning before reuse. Define crash recovery so PF success followed by JSON
failure is reconciled on the next cycle without inventing an exact change time.

`last-update` continues to describe status publication, **not endpoint changes**.
Notification consumers should checkpoint event IDs and tolerate retries. Keep
notification credentials, network delivery, and retry logic outside privileged
`maped`. The current JSON file is private; any unprivileged exporter needs a
separate access design, not weaker permissions on the ownership directory.
Decide and document schema-version compatibility before adding these fields.

## Implementation boundaries and tests

Suggested code boundaries:

- Pure service-config validation and deterministic assignment functions.
- Rule generation integrated with `maped-up`; no shell evaluation of JSON values.
- Daemon reconciliation/ownership extended with the selected assignments.
- `MapedStatus` extended with mappings and persistent endpoint events.

Required tests:

- Unit: valid/invalid configuration, allocation membership, stable assignments,
  TCP/UDP independence, capacity exhaustion, history deduplication, restart.
- Mocked daemon: create/change/remove services, address and PSID changes,
  expiry, query failure, PF load failure, JSON write failure, drift repair.
- OpenBSD: validate real generated rules; reach a local listener through an
  external port; verify optional table restrictions, dynamic membership changes,
  table persistence across anchor reloads, `from any`, and reply translation;
  exercise simultaneous inbound/outbound NAT and targeted state cleanup.

Acceptance: configuration alone drives dynamic anchor updates; status exposes
only successfully applied mappings; failures cannot extend lease authorization;
no unrelated rules or states are modified. Review state cleanup and outbound
NAT interaction before calling this production-ready.
