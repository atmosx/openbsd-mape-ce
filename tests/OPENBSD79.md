# OpenBSD 7.9 validation

The 7.9 patches target a clean `OPENBSD_7_9` CVS tree. Apply both with
`patch -p1`. The 7.8 and split patches are not part of this procedure.

## Repeatable checks

Record `uname -a`, the source CVS revisions, and checksums of both patches.
Keep a pristine copy of the affected source files. Apply the final patches
with no rejected hunks, fuzz, or offsets, and compare the resulting source
with the source used for the builds.

Build the kernel and base userland as described in the README. For isolated
parser testing without installing system headers, `pfctl` can instead be
built with `-I/usr/src/sys` added to its compiler flags. This is not an
installation procedure and does not update other PF consumers.

Run the repository tests (mocked networking and UID admission checks require no root):

```sh
make test
make pf-test OPENBSD_SRC=/usr/src
```

`make test` covers `maped(8)` lifecycle reconciliation, `OpenBSD::Pledge` and
`OpenBSD::Unveil` sandboxing (on OpenBSD), inbound publishing, `status.json`
reporting, `maped-up` / `maped-down` helper logic, parameter derivation, and
Prometheus metrics. `make pf-test` compiles extracted portions of the patched
`pf_lb.c` allocator and `pf_ioctl.c` validator with stubbed kernel types and
verifies IPv4/IPv6 non-echo address mapping, address-selection failure,
ICMP echo identifier bounds, and all supported offset/length/PSID combinations.
Neither replaces live kernel packet-path tests.

Run the DHCP lease-parser and Softwire46 fuzz regressions:

```sh
cd /usr/src/regress/sbin/dhcp6leased
make regress
```

Run the targeted PF parser cases without the regression Makefile's interface
creation hooks. Substitute the path to the newly built `pfctl` if objects
are outside the source tree:

```sh
cd /usr/src/regress/sbin/pfctl
pfctl=/usr/src/sbin/pfctl/pfctl
"$pfctl" -o none -nv -f - < pf116.in > /tmp/pf116.out
diff -u pf116.ok /tmp/pf116.out
if "$pfctl" -o none -nv -f - < pfail68.in > /tmp/pfail68.out 2>&1; then
    exit 1
fi
diff -u pfail68.ok /tmp/pfail68.out
```

Case 116 includes both MAP-E and the existing source-limiter `mask` keyword.
Case 68 covers malformed parameters, incompatible options, custom port
ranges with either endpoint changed, zero-length PSIDs, and an oversized
PSID length. Upstream case 115 is preserved.

## Validation evidence (`vm02`, OpenBSD 7.9 arm64)

- Both 7.9 patches apply to a pristine `OPENBSD_7_9` source tree without
  fuzz, offsets, or rejected hunks and match `src/` byte-for-byte.
- `pfctl`, `dhcp6leased`, and `dhcp6leasectl` build cleanly against the patched
  headers, and `pf_lb.o` and `pf_ioctl.o` compile in the `arm64 GENERIC.MP`
  kernel build configuration with `-Werror`.
- PF parser cases `pf116` and `pfail68` pass (including offset `0..15` bounds).
- DHCP regressions (`engine_test`, `parse_lease_test`, `fuzz_s46_test`) pass
  with `MALLOC_OPTIONS=S`, covering RFC 9915 message validation, S46 option
  opt-in, unknown TLV skipping, and prefix-span bounds.
- `make test` and `make pf-test` pass on OpenBSD 7.9 arm64 and locally under
  ASan/UBSan.

Current patch SHA256 values (updated when patches change):

```text
d752235ecad392468c9c5720049c87455ebacd38086a615742ff88e33b35da25  patch/pf-map-e-ce/mape79.patch
07bc1cf6381cfd9068f860e6994ba4d23ff2eb21714b7b3d8862c284a89ce8eb  patch/dhcp6leased-mape-softwire46-openbsd79.patch
```

## Deployment gate

Before production use, complete these checks on an isolated router with a
snapshot or full backup and console access:

- Boot the completed patched kernel and install matching rebuilt userland
  (including `dhcp6leasectl` with `-m` support).
- Verify firewall startup, rule loading, and every PF-consuming service in use.
- Exercise ordinary NAT and MAP-E with TCP, UDP, ICMP echo and non-echo traffic,
  verifying translated ports, TCP SYN MSS clamping, and ICMPv6 Packet Too Big
  admission.
- Exercise DHCP lease acquisition, renewal, changed parameters, daemon restart,
  and interface recovery with an appropriate DHCPv6 server and MAP-E peer.
- Test rollback of the matching kernel/userland pair.

Builds, parser regressions, and stubbed allocator tests alone do not establish
that this gate has passed. The migration remains experimental until the
packet-path and lifecycle checks are completed.
