# MAP-E Prometheus Metrics

This directory contains a small Prometheus textfile collector for an OpenBSD
MAP-E CE router.

The collector is intentionally split from the exporter:

```text
root cron
  -> /usr/local/sbin/mape-prometheus-metrics
  -> writes /var/prometheus/textfile/mape.prom atomically

non-root exporter or httpd
  -> serves the generated text file

Prometheus
  -> scrapes the metrics from another host
```

This keeps privileged commands such as `pfctl(8)`, `ifconfig(8)`, and
`dhcp6leasectl(8)` out of a long-running HTTP service.

## Install

Copy the script to the router:

```ksh
doas install -d -o root -g wheel -m 755 /usr/local/sbin
doas install -o root -g wheel -m 755 metrics/mape-prometheus-metrics /usr/local/sbin/mape-prometheus-metrics
```

Create the textfile directory:

```ksh
doas install -d -o root -g wheel -m 755 /var/prometheus/textfile
```

Run it once:

```ksh
doas /usr/local/sbin/mape-prometheus-metrics
cat /var/prometheus/textfile/mape.prom
```

The script reads `/etc/maped.conf` by default. Override paths if needed:

```ksh
doas /usr/local/sbin/mape-prometheus-metrics \
  -c /etc/maped.conf \
  -o /var/prometheus/textfile/mape.prom \
  -w pppoe0 \
  -g gif0
```

## Cron

Run once per minute:

```cron
* * * * * /usr/local/sbin/mape-prometheus-metrics >/dev/null 2>&1
```

This is intentionally cheap: it collects current PF counters, queue counters,
interface state, route state, DHCPv6 MAP-E lease state, and `maped-derive`
health, then exits.

## Serving With node_exporter

If `node_exporter` is available, use its textfile collector:

```ksh
node_exporter --collector.textfile.directory=/var/prometheus/textfile
```

Prometheus scrape example:

```yaml
scrape_configs:
  - job_name: openbsd-mape
    static_configs:
      - targets:
          - 192.168.121.1:9100
```

Restrict access with PF so only the Prometheus server can scrape the exporter.

## Serving With OpenBSD httpd

If you do not want node_exporter on the router, write directly under
`/var/www/htdocs/metrics`:

```ksh
doas install -d -o root -g daemon -m 755 /var/www/htdocs/metrics
doas /usr/local/sbin/mape-prometheus-metrics -o /var/www/htdocs/metrics/mape.prom
```

Cron example:

```cron
* * * * * /usr/local/sbin/mape-prometheus-metrics -o /var/www/htdocs/metrics/mape.prom >/dev/null 2>&1
```

Minimal `httpd.conf` example:

```conf
server "mape-metrics" {
	listen on 192.168.121.1 port 9101
	root "/htdocs"
	location "/metrics/mape.prom" {
		request strip 0
	}
}
```

Scrape example:

```yaml
scrape_configs:
  - job_name: openbsd-mape-textfile
    metrics_path: /metrics/mape.prom
    static_configs:
      - targets:
          - 192.168.121.1:9101
```

Again, restrict this listener with PF to the Prometheus host.

## Metrics

The script emits health gauges:

- `maped_up`
- `dhcp6leased_up`
- `dhcp6leased_mape_bound`
- `mape_gif_up`
- `mape_gif_running`
- `pppoe_session_up`
- `mape_anchor_portset_present`
- `mape_anchor_file_portset_present`
- `mape_default_route_v4`
- `mape_default_route_v6`
- `mape_derive_ok`

It emits PF state gauges:

- `pf_states`
- `pf_halfopen_tcp`

It emits PF cumulative counters using a `counter` label:

- `pf_counter_total{counter="short"}`
- `pf_counter_total{counter="state_mismatch"}`
- `pf_counter_total{counter="no_route"}`
- and the other counters from `pfctl -si`

It emits queue metrics for every queue returned by `pfctl -sq -v`:

- `pf_queue_packets_total{queue="mape_std"}`
- `pf_queue_bytes_total{queue="mape_std"}`
- `pf_queue_dropped_packets_total{queue="mape_std"}`
- `pf_queue_dropped_bytes_total{queue="mape_std"}`
- `pf_queue_length{queue="mape_std"}`
- `pf_queue_limit{queue="mape_std"}`

## Grafana Dashboard

Import `metrics/grafana-mape-pf-dashboard.json` into Grafana and select the
Prometheus data source that scrapes the router.

The dashboard includes:

- MAP-E control-plane health, including `maped`, `dhcp6leased`, DHCPv6 MAP-E
  lease state, gif/PPPoE interface state, route checks, PF anchor checks, and
  `maped-derive` health.
- PF state table panels for current states, half-open TCP states, and selected
  `pfctl -si` counter rates.
- MAP-E queue panels for throughput, packet rate, drops, queue fill, and a
  current queue snapshot.

The dashboard uses Grafana's importable dashboard JSON model with current panel
types such as stat, state timeline, time series, bar gauge, and table panels.
Template variables are derived from Prometheus labels:

- `$job` from `label_values(maped_up, job)`
- `$instance` from `label_values(maped_up{job=~"$job"}, instance)`
- `$queue` from `pf_queue_packets_total`
- `$pf_counter` from `pf_counter_total`

If the scrape job is not named `openbsd-mape`, choose the correct job from the
dashboard variable after import.

## Suggested Alerts

These are useful first-pass Prometheus alert expressions:

```promql
maped_up == 0
dhcp6leased_up == 0
dhcp6leased_mape_bound == 0
mape_gif_up == 0
pppoe_session_up == 0
mape_anchor_portset_present == 0
mape_default_route_v4 == 0
mape_default_route_v6 == 0
mape_derive_ok == 0
```

Counter-rate alerts:

```promql
increase(pf_counter_total{counter="no_route"}[5m]) > 0
increase(pf_queue_dropped_packets_total{queue="mape_std"}[5m]) > 0
increase(pf_counter_total{counter="state_mismatch"}[5m]) > 100
increase(pf_counter_total{counter="short"}[5m]) > 100
```

Queue backlog:

```promql
pf_queue_length{queue="mape_std"} > 0
```

Tune thresholds after a few days of baseline data. `state_mismatch` and `short`
can have background noise; their rate during symptoms is more useful than their
absolute value.

## Relationship To `mape-health-snapshot`

Use this script for continuous dashboards and alerts.

Use `mape-health-snapshot` for forensic bundles when something is wrong. The
snapshot collector captures much more context, including configs, routes,
tcpdump event captures, logs, and PF state samples.
