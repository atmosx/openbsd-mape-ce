#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mape-metrics-tests.XXXXXXXXXX")
trap 'rm -rf "$tmp"' EXIT

test_no=0

ok()
{
	test_no=$((test_no + 1))
	printf 'ok %d - %s\n' "$test_no" "$1"
}

fail()
{
	printf 'not ok %d - %s\n' "$((test_no + 1))" "$1" >&2
	if [ "$#" -gt 1 ] && [ -s "$2" ]; then
		sed 's/^/# /' "$2" >&2
	fi
	exit 1
}

require_line()
{
	line=$1
	file=$2
	name=$3

	if grep -Fqx "$line" "$file"; then
		return
	fi

	printf 'missing line: %s\n' "$line" > "$tmp/missing"
	fail "$name" "$tmp/missing"
}

run_metrics_with_pfctl_exporter_stubs()
{
	bin="$tmp/metrics-bin"
	conf="$tmp/metrics.conf"
	out="$tmp/mape.prom"
	mkdir -p "$bin"

	cat > "$bin/pfctl" <<'EOF'
#!/bin/sh
case "$*" in
"-si")
	cat <<'OUT'
Status: Enabled for 0 days 00:00:00
State Table                          Total             Rate
  current entries                       12
  half-open tcp                          3
  searches                         4994939            2.3/s
Counters
  bad-offset                             1            0.0/s
  fragment                               0            0.0/s
  short                                  2            0.0/s
  normalize                              0            0.0/s
  memory                                 0            0.0/s
  bad-timestamp                          0            0.0/s
  congestion                             0            0.0/s
  ip-option                              0            0.0/s
  proto-cksum                            0            0.0/s
  state-mismatch                         4            0.0/s
  state-insert                           0            0.0/s
  state-limit                            0            0.0/s
  src-limit                              0            0.0/s
  synproxy                               0            0.0/s
  translate                              0            0.0/s
  no-route                               5            0.0/s
OUT
	;;
"-sq -v")
	cat <<'OUT'
queue mape_std
  [ pkts: 7  bytes: 700  dropped pkts: 1 bytes: 100 ]
  [ qlength: 2/50 ]
OUT
	;;
"-a mape -sr")
	printf '%s\n' 'match out on gif0 nat-to 192.0.2.1 map-e-portset 16/6/0'
	;;
"-vvs info")
	cat <<'OUT'
Status: Enabled for 0 days 00:00:00
State Table                          Total             Rate
  current entries                       12
  half-open tcp                          3
  searches                         4994939            2.3/s
Counters
  bad-offset                             1            0.0/s
Syncookies
  mode adaptive
  active active
OUT
	;;
"-vvs Interfaces")
	printf '%s\n' 'em0'
	printf '\tReferences:  27                \n'
	printf '\tCleared:     Sun Nov 19 18:50:41 2023\n'
	printf '\tIn4/Block:   [ Packets: 184339             Bytes: 29172941           ]\n'
	printf '\tOut6/Pass:   [ Packets: 5                  Bytes: 500                ]\n'
	printf '%s\n' 'lo0 (skip)'
	;;
"-Pvs rules")
	cat <<'OUT'
pass in quick on em0 from any to any
  [ Evaluations: 9                  Packets: 8                  Bytes: 700                States: 6                  ]
OUT
	;;
"-vvs Tables")
	printf '%s\t%s\n' '--a-r--' 'prometheus6'
	printf '\tAddresses:   12\n'
	printf '\tCleared:     Sun Nov 19 18:50:41 2023\n'
	printf '\tReferences:  [ Anchors: 0                  Rules: 2                  ]\n'
	printf '\tEvaluations: [ NoMatch: 0                  Match: 25                 ]\n'
	printf '\tIn/Pass:     [ Packets: 461268             Bytes: 57925850           ]\n'
	;;
*)
	exit 1
	;;
esac
EOF
	chmod +x "$bin/pfctl"

	cat > "$bin/ifconfig" <<'EOF'
#!/bin/sh
case "$1" in
gif0) printf '%s\n' 'gif0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST>' ;;
pppoe0) printf '%s\n' '	status: active' ;;
*) exit 1 ;;
esac
EOF
	chmod +x "$bin/ifconfig"

	cat > "$bin/dhcp6leasectl" <<'EOF'
#!/bin/sh
printf '%s\n' 'MAP-E option present'
EOF
	chmod +x "$bin/dhcp6leasectl"

	cat > "$bin/netstat" <<'EOF'
#!/bin/sh
cat <<'OUT'
default            198.51.100.1        UGS        gif0
default            fe80::1             UGS        pppoe0
OUT
EOF
	chmod +x "$bin/netstat"

	cat > "$bin/rcctl" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$bin/rcctl"

	cat > "$bin/maped-derive" <<'EOF'
#!/bin/sh
printf '%s\n' 'CE_IPV6=2001:db8::1'
printf '%s\n' 'MAPE_IPV4=192.0.2.1'
EOF
	chmod +x "$bin/maped-derive"

	cat > "$conf" <<EOF
PFCTL="$bin/pfctl"
IFCONFIG="$bin/ifconfig"
DHCP6LEASECTL="$bin/dhcp6leasectl"
NETSTAT="$bin/netstat"
RCCTL="$bin/rcctl"
MAPED_DERIVE="$bin/maped-derive"
EOF

	if sh "$repo/metrics/mape-prometheus-metrics" -c "$conf" -o "$out" -w pppoe0 -g gif0; then
		:
	else
		fail "mape-prometheus-metrics runs with pfctl stubs" "$out"
	fi

	name="mape-prometheus-metrics exports pfctl_exporter metric names and types"
	require_line '# TYPE pfctl_state_table_current_entries gauge' "$out" "$name"
	require_line 'pfctl_state_table_current_entries 12' "$out" "$name"
	require_line '# TYPE pfctl_state_table_searches_total counter' "$out" "$name"
	require_line 'pfctl_state_table_searches_total 4994939' "$out" "$name"
	require_line '# TYPE pfctl_counters_bad_offset_total counter' "$out" "$name"
	require_line 'pfctl_counters_bad_offset_total 1' "$out" "$name"
	require_line 'pfctl_syncookies_mode{mode="adaptive"} 1' "$out" "$name"
	require_line '# TYPE pfctl_interface_packets_total counter' "$out" "$name"
	require_line 'pfctl_interface_packets_total{interface="em0",direction="In",family="ipv4",action="Block"} 184339' "$out" "$name"
	require_line '# TYPE pfctl_rule_evaluations_total counter' "$out" "$name"
	require_line 'pfctl_rule_evaluations_total{rule="pass in quick on em0 from any to any"} 9' "$out" "$name"
	require_line '# TYPE pfctl_table_flags_active gauge' "$out" "$name"
	require_line 'pfctl_table_flags_active{table="prometheus6"} 1' "$out" "$name"
	require_line '# TYPE pfctl_table_match_evaluations_total counter' "$out" "$name"
	require_line 'pfctl_table_match_evaluations_total{table="prometheus6"} 25' "$out" "$name"
	ok "$name"
}

run_metrics_with_pfctl_exporter_stubs

printf '1..%d\n' "$test_no"
