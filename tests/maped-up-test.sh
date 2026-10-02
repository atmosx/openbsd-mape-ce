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
EOF
cat > "$tmp/bin/pfctl" <<'EOF'
#!/bin/sh
printf 'pfctl %s\n' "$*" >> "$CALLS"
EOF
cat > "$tmp/bin/route" <<'EOF'
#!/bin/sh
printf 'route %s\n' "$*" >> "$CALLS"
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
printf '1..%s\n' "$n"
