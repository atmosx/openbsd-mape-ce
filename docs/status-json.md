# MAP-E status and allocation history

`maped` publishes **`/var/db/maped/status.json`**, or
`$MAPED_STATE_DIR/status.json` when that directory is configured. It uses
OpenBSD base Perl's `JSON::PP`; no CPAN package or `jq` is required.

The file is separate from `lease.state` and `applied.conf`. It is a reporting
interface, **never authorization to configure a tunnel or keep a lease alive**.
It is kept in the persistent state directory so address history survives
reboots. Version 1 is root-readable (0600, inside the existing private state
directory); privileged applications can read it directly. Do not loosen the
permissions of the ownership directory to expose this file. A future public
export can be added separately if unprivileged monitoring needs it.

## Updates and validity

The daemon atomically replaces the complete JSON file on every reconciliation
cycle, including unchanged healthy renewals/health checks (normally every 30
seconds), and during withdrawal and application transitions. Readers see either
the previous complete document or the next complete document, not partial JSON.
Temporary files are created in the same directory with mode 0600.

`last-update` is a UTC ISO 8601 timestamp (`YYYY-MM-DDTHH:MM:SSZ`).
`updated_at_epoch` is the same publication time in Unix seconds. These indicate
publication, not necessarily a new address or a successful DHCP query.

| `status` | Meaning |
|---|---|
| `initializing` | Started, but no live lease/runtime confirmation yet |
| `applying` | Configuration is being applied; no current usable allocation advertised |
| `active` | Live lease confirmed and configuration applied or checked healthy |
| `degraded` | Live query failed; last successfully applied allocation may remain authorized until its previously confirmed deadline |
| `inactive` | Service withdrawn or expired; no current usable allocation advertised |
| `error` | Derivation, inspection, or configuration/cleanup could not be established successfully |

`reason` supplies context. `last_confirmed_at` records the most recent successful
live lease confirmation in this process. `lease_expires_at` is a wall-clock
estimate of its expiry. The daemon continues to enforce validity using its
existing **monotonic** deadline; timestamps in this document do not replace it.

For active service, `allocation` and `port_set` contain the current configuration.
On a transient query failure they may contain the previous applied allocation,
with `status: degraded`; the confirmation timestamp is not advanced. Other
states have null allocation/port-set fields. Failed cleanup is explicitly an
error: null allocation does not prove that every kernel object was removed.

A stopped/crashed daemon, failed disk write, or a machine that is off cannot
refresh a file. Consumers **must check freshness**, status, and lease expiry;
never assume that `active` in an old file means service is still active. One-shot
`maped -1` publishes a snapshot, not a continuously maintained status feed.
Wall-clock adjustments can affect the reporting timestamps.

A publication failure is logged and makes the reconciliation cycle unsuccessful
without tearing down otherwise valid networking. The previous file may remain;
freshness checks are essential. History is loaded before networking changes at
startup. Invalid JSON, an unsupported schema, or invalid history structure stops
startup rather than silently discarding historical observations. Back up and
move a damaged status file aside before restarting if recovery is necessary.

## Schema version 1

Top-level fields:

- `schema_version`: integer 1; applications should reject unknown versions.
- `status`, `reason`, `last-update`, `updated_at_epoch`: reporting state/time.
- `lease_interface`, `tunnel_interface`: interfaces managed by this daemon.
- `last_confirmed_at`, `lease_expires_at`: UTC timestamps, or null.
- `allocation`: current applied address/PSID tuple, or null.
- `port_set`: complete inclusive port ranges and counts, or null.
- `record`: ordered persistent array of observed allocation periods.

An allocation contains:

```json
{
  "ipv4_address": "87.202.58.210",
  "ce_ipv6_address": "2a02:586:6234:bf00:0:57ca:3ad2:3f",
  "br_ipv6_address": "2a02:586::406",
  "delegated_ipv6_prefix": "2a02:586:6234:bf00::/56",
  "offset": 6,
  "psid_length": 6,
  "psid": 63
}
```

These are **all MAP-E addresses/prefixes known to the applied plan**, not an
inventory of unrelated WAN SLAAC, link-local, or LAN addresses. IPv4 and CE IPv6
addresses, the delegated prefix, and the provider's BR are kept together so
applications can distinguish customer renumbering from BR or PSID changes.

`port_set` contains `restricted` (boolean), `offset`, `psid_length`, `psid`,
`protocols` (`tcp`, `udp`), `block_count`, `port_count`, and `ranges`.
Each range is an object with inclusive integer `first` and `last` fields.
For `6/6/63` there are 63 ranges, beginning 2032–2047 and ending 65520–65535,
with 1008 ports per transport protocol. The file includes **every range**.

Zero-length PSIDs are represented as unrestricted with the full 0–65535 numeric
space. This describes the absence of a MAP sharing restriction, not a promise
that every port (including port zero) is usable by normal applications.
Port allocation never implies a PF pass rule, an SSH listener, a redirect, or
ISP permission for inbound traffic. ICMP echo identifiers use the same mapping
arithmetic but are not TCP/UDP service ports.

## History semantics

Each `record` entry has:

```json
{
  "first-seen": "2026-10-03T10:00:00Z",
  "last-seen": "2026-10-04T12:00:00Z",
  "allocation": { "...": "same allocation fields as above" }
}
```

The abbreviated allocation above is illustrative, not actual output.

- Records are created only for successfully applied/healthy configurations.
- An unchanged allocation refreshes the last entry's `last-seen` date, rather
  than appending a record on every renewal.
- A change to any address, prefix, offset, PSID length, or PSID appends an entry.
- Returning to a previously used tuple after another tuple creates a new entry.
- Restart, withdrawal, or temporary query failure preserves history. These do
  not create fictional address changes or advance `last-seen` without a
  successful observation.
- First/last seen are **observation times**, not exact ISP assignment times.
  Unchanged observations spanning an outage do not prove continuous service.
  Changes while the daemon is stopped cannot be reconstructed.
- History starts when this feature is deployed. It cannot recover earlier ISP
  changes from a current DHCP lease.
- No automatic pruning is performed: all observed transitions are retained.
  The full JSON is rewritten atomically each cycle, so long histories increase
  disk I/O. Back up the file; rotation/retention is an explicit future policy.

To measure IPv4 churn, compare `ipv4_address` between adjacent records and count
only actual address changes. A PSID-only or BR-only change is a separate event.
For IPv6 churn compare the delegated prefix and CE address independently. The
previous `last-seen` and next `first-seen` bound the observation gap, not an exact
ISP change instant. Keep this uncertainty when computing average intervals.

## Reading without additional packages

Display the pretty-printed status:

```sh
doas less /var/db/maped/status.json
```

Extract an nmap-style range list (this command does not perform a scan):

```sh
doas /usr/bin/perl -MJSON::PP -0777 -ne '
  my $s = decode_json($_);
  die "not active\n" unless $s->{schema_version} == 1 && $s->{status} eq "active";
  die "stale status\n" if time - $s->{updated_at_epoch} > 90;
  print join(",", map { "$_->{first}-$_->{last}" }
      @{$s->{port_set}{ranges}}), "\n";
' /var/db/maped/status.json
```

The 90-second threshold is an example for the default 30-second cycle; select a
threshold appropriate to the configured health-check interval. Consumers making
operational decisions should also check `lease_expires_at` and handle future
publication times after wall-clock adjustments.

Print the address/PSID timeline:

```sh
doas /usr/bin/perl -MJSON::PP -0777 -ne '
  my $s = decode_json($_);
  for my $r (@{$s->{record}}) {
    my $a = $r->{allocation};
    print join("\t", $r->{"first-seen"}, $r->{"last-seen"},
        $a->{ipv4_address}, $a->{delegated_ipv6_prefix},
        $a->{ce_ipv6_address}, $a->{br_ipv6_address},
        "$a->{offset}/$a->{psid_length}/$a->{psid}"), "\n";
  }
' /var/db/maped/status.json
```

## Tests and deployment

`tests/maped-status.t` tests the calculator, range boundaries, invalid inputs,
UTC timestamps, history transitions, restart preservation, malformed history,
permissions, and atomic-write failure cleanup. `tests/maped-daemon.t` uses mocked
networking commands to check integration with active/no-op cycles, PSID changes,
withdrawal, failed application, transient query failures, and expiry.

Run `make test` and, for strict TAP failure checking:

```sh
prove tests/maped-status.t tests/maped-daemon.t
```

Install the new `MapedStatus.pm` alongside `Maped.pm` using `make install-bin`,
and restart `maped` to enable reporting. No PF or DHCP patch change is needed.
Validate the new module on OpenBSD as well: local mock tests are not proof that
the target's pledge/unveil execution and packet path have been exercised.
