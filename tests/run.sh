#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$repo/tests/fixtures"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/maped-tests.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

test_no=0

ok()
{
	test_no=$((test_no + 1))
	printf 'ok %d - %s\n' "$test_no" "$1"
}

skip()
{
	test_no=$((test_no + 1))
	printf 'ok %d - %s # SKIP %s\n' "$test_no" "$1" "$2"
}

fail()
{
	printf 'not ok %d - %s\n' "$((test_no + 1))" "$1" >&2
	if [ "$#" -gt 1 ] && [ -s "$2" ]; then
		sed 's/^/# /' "$2" >&2
	fi
	exit 1
}

compare()
{
	name=$1
	want=$2
	got=$3

	if diff -u "$want" "$got" > "$tmp/diff"; then
		ok "$name"
	else
		fail "$name" "$tmp/diff"
	fi
}

run_derive_from_lease_file()
{
	out="$tmp/derive-lease-file.out"
	env -i PATH="${PATH:-/bin:/usr/bin}" \
	    LEASE_FILE="$fixtures/lease-file.txt" \
	    perl "$repo/maped/maped-derive" > "$out"
	compare "maped-derive parses dhcp6leased lease file" \
	    "$fixtures/derive.expected" "$out"
}

run_derive_from_dhcp6leasectl()
{
	cmd="$tmp/dhcp6leasectl"
	out="$tmp/derive-dhcp6leasectl.out"

	cat > "$cmd" <<EOF
#!/bin/sh
cat "$fixtures/dhcp6leasectl.txt"
EOF
	chmod +x "$cmd"

	env -i PATH="${PATH:-/bin:/usr/bin}" \
	    LEASE_IF=pppoe0 \
	    DHCP6LEASECTL="$cmd" \
	    perl "$repo/maped/maped-derive" > "$out"
	compare "maped-derive parses dhcp6leasectl output" \
	    "$fixtures/derive.expected" "$out"
}

run_derive_from_zero_psid_lease()
{
	out="$tmp/derive-zero-psid.out"
	env -i PATH="${PATH:-/bin:/usr/bin}" \
	    LEASE_FILE="$fixtures/cosmote-like-zero-psid.txt" \
	    perl "$repo/maped/maped-derive" > "$out"
	compare "maped-derive handles zero-length DHCP PSID" \
	    "$fixtures/cosmote-like-zero-psid.expected" "$out"
}

run_maped_once_with_stub_helper()
{
	if [ "$(id -u)" -ne 0 ]; then
		skip "maped one-shot runs stub helper" "requires root"
		return
	fi

	state_dir="$tmp/state"
	conf="$tmp/maped.conf"
	helper="$state_dir/maped-up"
	out="$tmp/maped.out"
	mkdir -p "$state_dir"

	cat > "$helper" <<'EOF'
#!/bin/sh
set -eu
. "$1"
printf '%s\n' "$1" > "$MAPED_STATE_DIR/up.called"
EOF
	chmod +x "$helper"

	cat > "$conf" <<EOF
LEASE_FILE="$fixtures/lease-file.txt"
MAPED_STATE_DIR="$state_dir"
MAPED_UP="$helper"
MAPED_LOG_LEVEL="warn"
EOF

	if perl "$repo/maped/maped" -1 -f -p -i 1 "$conf" > "$out" 2>&1; then
		:
	else
		fail "maped one-shot runs stub helper" "$out"
	fi

	test -f "$state_dir/up.called" ||
	    fail "maped one-shot records helper execution" "$out"
	ok "maped one-shot records helper execution"

	expected_state="$tmp/state.expected"
	perl -0pe 's/\n\z//' "$fixtures/state.expected" > "$expected_state"
	compare "maped one-shot writes lease state" \
	    "$expected_state" "$state_dir/lease.state"
}

run_derive_from_lease_file
run_derive_from_dhcp6leasectl
run_derive_from_zero_psid_lease
run_maped_once_with_stub_helper

printf '1..%d\n' "$test_no"
