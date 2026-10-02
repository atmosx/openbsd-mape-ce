#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/maped-down-tests.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$tmp/bin/ifconfig" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ]; then
	if [ "$1" = gif0 ]; then
		echo " tunnel: inet6 $TUNNEL_SOURCE --> 2001:db8::2 ttl 64"
	else
		echo ' inet6 2001:db8::1 prefixlen 128'
	fi
else
	echo "ifconfig $*" >> "$CALLS"
fi
EOF
cat > "$tmp/bin/pfctl" <<'EOF'
#!/bin/sh
echo "pfctl $*" >> "$CALLS"
EOF
cat > "$tmp/bin/route" <<'EOF'
#!/bin/sh
if [ "$1" = -n ]; then
	echo " interface: $ROUTE_IF"
else
	echo "route $*" >> "$CALLS"
fi
EOF
chmod +x "$tmp/bin/"*
n=0
run()
{
	source=$1 route_if=$2 alias=$3
	cat > "$tmp/conf" <<EOF
WAN_IF=pppoe0
GIF_IF=gif0
CE_IPV6=2001:db8::1
BR_IPV6=2001:db8::2
MAPED_ALIAS_OWNED=$alias
EOF
	: > "$tmp/calls"
	env -i PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" \
	    TUNNEL_SOURCE="$source" ROUTE_IF="$route_if" \
	    sh "$repo/maped/maped-down" "$tmp/conf" > /dev/null
	if [ "$source" = 2001:db8::1 ]; then
		grep -qx 'ifconfig gif0 destroy' "$tmp/calls"
	else
		! grep -q 'destroy' "$tmp/calls"
	fi
	if [ "$source" = 2001:db8::1 ] && [ "$route_if" = gif0 ]; then
		grep -q '^route delete' "$tmp/calls"
	else
		! grep -q '^route delete' "$tmp/calls"
	fi
	if [ "$alias" = 1 ]; then
		grep -qx 'ifconfig pppoe0 inet6 2001:db8::1 delete' "$tmp/calls"
	else
		! grep -q 'inet6 .* delete' "$tmp/calls"
	fi
	n=$((n + 1))
	echo "ok $n - ownership source=$source route=$route_if alias=$alias"
}
run 2001:db8::1 gif0 1
run 2001:db8::1 em0 1
run 2001:db8::3 gif0 1
run 2001:db8::1 gif0 0
printf '1..%s\n' "$n"
