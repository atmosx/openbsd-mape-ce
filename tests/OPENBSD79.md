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

Run the repository tests as root to include the daemon one-shot test:

```sh
doas make test
make pf-test OPENBSD_SRC=/usr/src
```

`pf-nat-test.sh` compiles extracted portions of the patched allocator with
stubbed types and address/state dependencies. It checks IPv4/IPv6 non-echo
address selection, address-selection failure, ordinary echo identifier
ranges, preservation of MAP-E echo ranges, all supported offset/length
combinations at minimum/maximum PSIDs, and both first-success and exhausted
port-set searches. It does not replace kernel packet tests.

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

## Original 7.9 validation evidence

Checks on `vm02` (OpenBSD 7.9, arm64):

- Both final patches applied to a pristine copy of the affected 7.9 files
  without fuzz, offsets, or rejected hunks. All resulting files matched the
  build tree byte-for-byte.
- `pfctl`, `dhcp6leased`, and `dhcp6leasectl` built successfully.
- PF parser cases 116 and 68 passed, including exit-status checks.
- DHCP parser/fuzz regressions passed, including `MALLOC_OPTIONS=S`.
- Repository tests passed as root, including daemon helper execution and
  state-file checks.
- The extracted allocator tests passed on OpenBSD and locally; the local
  run also passed with undefined-behavior sanitization. The pre-fix allocator
  failed the same test as a negative control.
- The corrected `pf_lb.o` compiled in the arm64 GENERIC.MP configuration.

Current patch SHA256 values (updated when patches change):

```text
bf4494f3133d3e79b2d9608c8e2a26d745df2aabcb87a22ae036e2e5b25768d9  patch/pf-map-e-ce/mape79.patch
a9b4e9d8f291864ae7445bc24d06c6f9d5bbdc62343c27a1522a598e2089ace6  patch/dhcp6leased-mape-softwire46-openbsd79.patch
```

The full arm64 GENERIC.MP kernel build completed successfully (exit status 0).
Its log is `/tmp/mape79-final-kernel.log`; the status is recorded in
`/tmp/mape79-final-kernel.status`, and the kernel is
`/tmp/mape79-kernel-arm64/bsd` on the VM.
No kernel, headers, or base userland were installed, and the VM was not rebooted.
Full base-userland build, patched-kernel boot, and packet-path tests remain
outstanding.

## Deployment gate

Before production use, complete these checks on an isolated router with a
snapshot or full backup and console access:

- Boot the completed patched kernel and install matching rebuilt userland.
- Verify firewall startup, rule loading, and every PF-consuming service in use.
- Exercise ordinary NAT and MAP-E with TCP, UDP, ICMP echo and non-echo traffic.
- Verify actual translated ports belong to the assigned set, including at
  exhaustion; verify return traffic and path-MTU-related ICMP handling.
- Exercise DHCP lease acquisition, renewal, changed parameters, daemon restart,
  and interface recovery with an appropriate DHCPv6 server and MAP-E peer.
- Test rollback of the matching kernel/userland pair.

Builds, parser regressions, and stubbed allocator tests alone do not establish
that this gate has passed. The migration remains experimental until the
packet-path and lifecycle checks are completed.

## Follow-up regression checks

The MAP-E opt-in fix was built and its DHCP regressions run in an isolated
build directory on vm02 (OpenBSD 7.9 arm64). The engine regression extracts
the actual packet parser and stubs state transitions; it checks acceptance
with MAP-E enabled and rejection while disabled. It is not a live DHCP
exchange or a kernel packet-path test. No running services were changed.

The kernel-import fix adds the 7.9 `pf_ioctl.c` snapshot (CVS revision 1.430)
to the source subset. Its patch is against that upstream file, not an
addition to the OpenBSD tree. `pf_ioctl.o` and `pf_lb.o` compile with the
7.9 arm64 GENERIC.MP flags, including `-Werror`, in a temporary directory.
`make pf-test` also checks every byte-sized offset/length combination and
PSID boundaries at the kernel validator. This does not exercise live ioctls.
