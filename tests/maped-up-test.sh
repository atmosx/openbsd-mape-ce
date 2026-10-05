#!/bin/sh
# Run the real helper with mocked networking commands; no root is needed.
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/maped-up-tests.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$tmp/bin/ifconfig" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ]; then
	if [ "$1" = pppoe0 ]; then
		[ "$WAN_TEST_MTU" != missing ] || exit 1
		printf 'pppoe0: flags=8851<UP> mtu %s\n' "$WAN_TEST_MTU"
	fi
	exit 0
fi
printf 'ifconfig %s\n' "$*" >> "$CALLS"
# OpenBSD removes interface routes when the GIF is destroyed.
if [ "$1 $2" = 'gif0 destroy' ] && [ -n "${ROUTE_STATE:-}" ]; then
	rm -f "$ROUTE_STATE"
fi
EOF
cat > "$tmp/bin/pfctl" <<'EOF'
#!/bin/sh
printf 'pfctl %s\n' "$*" >> "$CALLS"
[ "${PF_FAIL:-}" != "$3" ] || exit 1
EOF
cat > "$tmp/bin/route" <<'EOF'
#!/bin/sh
if [ "$1" = -n ] && [ "$2" = get ]; then
	[ -n "${ROUTE_TEST_IF:-}" ] || exit 1
	[ -z "${ROUTE_STATE:-}" ] || [ -f "$ROUTE_STATE" ] || exit 1
	printf '    gateway: %s\n  interface: %s\n' "$ROUTE_TEST_GW" "$ROUTE_TEST_IF"
	exit 0
fi
printf 'route %s\n' "$*" >> "$CALLS"
if [ -n "${ROUTE_STATE:-}" ]; then
	case "$1" in
	delete)
		[ "${ROUTE_DELETE_FAIL:-0}" = 0 ] || exit 1
		[ -f "$ROUTE_STATE" ] || { echo 'default: not in table' >&2; exit 1; }
		rm "$ROUTE_STATE" ;;
	add)
		[ ! -f "$ROUTE_STATE" ] || exit 1
		touch "$ROUTE_STATE" ;;
	esac
fi
EOF
cat > "$tmp/bin/derive" <<'EOF'
#!/bin/sh
printf '%s\n' PD_PREFIX=2001:db8::/56 CE_IPV6=2001:db8::1 \
    BR_IPV6=2001:db8::2 MAPE_IPV4=192.0.2.1 PSID_OFFSET=6 PSID_LEN=8 PSID=1
EOF
chmod +x "$tmp/bin/"*
cat > "$tmp/base.conf" <<EOF
WAN_IF=pppoe0
GIF_IF=gif0
LAN_NET=192.168.1.0/24
PF_ANCHOR_FILE="$tmp/anchor"
MAPED_DERIVE="$tmp/bin/derive"
EOF
n=0
run()
{
	wan=$1 setting=$2 expected=$3
	cp "$tmp/base.conf" "$tmp/conf"
	[ "$setting" = omitted ] || printf 'GIF_MTU="%s"\n' "$setting" >> "$tmp/conf"
	: > "$tmp/calls"
	rm -f "$tmp/anchor"
	if env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" \
	    WAN_TEST_MTU="$wan" sh "$repo/maped/maped-up" "$tmp/conf" \
	    > "$tmp/output" 2>&1; then
		[ "$expected" != fail ] || { echo "unexpected success: $wan $setting"; exit 1; }
		grep -qx "ifconfig gif0 mtu $expected" "$tmp/calls"
		grep -qx "match out on gif0 inet proto tcp flags S/SA scrub (max-mss $((expected - 40)))" "$tmp/anchor"
		if grep -Eq '^pass in .* on gif0 inet ' "$tmp/anchor"; then
			echo 'generated anchor must not admit unsolicited tunnel IPv4 traffic' >&2
			exit 1
		fi
	else
		[ "$expected" = fail ] || { echo "unexpected failure: $wan $setting"; exit 1; }
		[ ! -s "$tmp/calls" ]
		[ ! -f "$tmp/anchor" ]
	fi
	n=$((n + 1))
	echo "ok $n - WAN=$wan GIF_MTU=$setting expected=$expected"
}
run 1492 auto 1452
run 1500 auto 1460
run 1492 omitted 1452
run 1500 1452 1452
run 1492 1280 1280
run 1492 8192 8192
run 1280 auto fail
run 8233 auto fail
run missing auto fail
run invalid auto fail
run 1492 1279 fail
run 1492 8193 fail
run 1492 invalid fail
run 1492 01452 fail
run 1492 999999999999999999999 fail
# An unrelated default route must be rejected before changing PF or interfaces.
cp "$tmp/base.conf" "$tmp/conf"
: > "$tmp/calls"
if env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" \
    WAN_TEST_MTU=1492 ROUTE_TEST_IF=em0 ROUTE_TEST_GW=192.0.2.254 \
    sh "$repo/maped/maped-up" "$tmp/conf" > "$tmp/output" 2>&1; then
	echo 'accepted an unrelated default route' >&2; exit 1
fi
[ ! -s "$tmp/calls" ]
n=$((n + 1)); echo "ok $n - preserve an unrelated default route"
: > "$tmp/calls"
touch "$tmp/route-state"
env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" \
    WAN_TEST_MTU=1492 ROUTE_TEST_IF=gif0 ROUTE_TEST_GW=0.0.0.1 \
    ROUTE_STATE="$tmp/route-state" \
    sh "$repo/maped/maped-up" "$tmp/conf" > "$tmp/output" 2>&1
grep -qx 'route delete -inet default -ifp gif0 0.0.0.1' "$tmp/calls"
grep -qx 'route add -inet default -ifp gif0 0.0.0.1' "$tmp/calls"
[ -f "$tmp/route-state" ]
awk '/^route delete / { deleted = 1 }
    /^ifconfig gif0 destroy$/ { if (!deleted) exit 1; destroyed = 1 }
    END { if (!destroyed) exit 1 }' "$tmp/calls"
n=$((n + 1)); echo "ok $n - delete owned route before interface destruction and restore it"
: > "$tmp/calls"
if env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" \
    WAN_TEST_MTU=1492 ROUTE_TEST_IF=gif0 ROUTE_TEST_GW=0.0.0.1 \
    ROUTE_STATE="$tmp/route-state" ROUTE_DELETE_FAIL=1 \
    sh "$repo/maped/maped-up" "$tmp/conf" > "$tmp/output" 2>&1; then
	echo 'ignored owned route deletion failure' >&2; exit 1
fi
[ -f "$tmp/route-state" ]
if grep -Eq '^ifconfig gif0 destroy$|^route add ' "$tmp/calls"; then
	echo 'continued rebuilding after route deletion failure' >&2; exit 1
fi
n=$((n + 1)); echo "ok $n - do not ignore route deletion errors"
# Exercise the real candidate renderer and complete-anchor validation/load.
cp "$tmp/base.conf" "$tmp/conf"
cat >> "$tmp/conf" <<'EOF'
MAPE_IPV4=192.0.2.1
PSID_OFFSET=6
PSID_LEN=8
PSID=1
MAPED_PUBLISH_JSON='[{"external_address":"192.0.2.1","external_port":1028,"name":"web","protocol":"tcp","source_table":"trusted","target_address":"127.0.0.1","target_port":8080}]'
EOF
: > "$tmp/calls"
env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" WAN_TEST_MTU=1492 \
    sh "$repo/maped/maped-up" "$tmp/conf" > "$tmp/output" 2>&1
grep -q 'from <trusted> to 192.0.2.1 port 1028 rdr-to 127.0.0.1 port 8080' "$tmp/anchor"
grep -q 'map-e-portset 6/8/1' "$tmp/anchor"
grep -q 'max-mss 1412' "$tmp/anchor"
awk '/^pfctl -a mape -nf / { checked = 1 }
    /^pfctl -a mape -f / { if (!checked) exit 1; loaded = 1 }
    END { if (!loaded) exit 1 }' "$tmp/calls"
n=$((n + 1)); echo "ok $n - validate and load complete publishing anchor"
for fail in -nf -f; do
    : > "$tmp/calls"
    if env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" WAN_TEST_MTU=1492 PF_FAIL="$fail" \
        sh "$repo/maped/maped-up" "$tmp/conf" > "$tmp/output" 2>&1; then
        echo "ignored PF failure $fail" >&2; exit 1
    fi
    if [ "$fail" = -nf ] && grep -q '^pfctl -a mape -f ' "$tmp/calls"; then
        echo 'loaded an invalid anchor' >&2; exit 1
    fi
    n=$((n + 1)); echo "ok $n - propagate publishing PF failure $fail"
done
printf '1..%s\n' "$n"
