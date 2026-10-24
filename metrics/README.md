# MAP-E Prometheus Metrics

This directory contains the Prometheus textfile collector and Grafana dashboard
for an OpenBSD MAP-E CE router.

## Contents

- `mape-prometheus-metrics`: short-lived root collector that writes
  `/var/prometheus/textfile/mape.prom` atomically.
- `grafana-map-e-ce-pfctl-dashboard.json`: Grafana dashboard for MAP-E CE,
  `maped`, PF queues, node_exporter textfile freshness, and
  pfctl-compatible metrics.
- `LICENSE`: BSD-3-Clause license for the metrics collector/dashboard work
  derived from `pfctl_exporter`.

## Install

Install the collector on the router:

```ksh
cd /usr/local/src/openbsd-mape-ce
doas make metrics-install
doas install -d -o root -g wheel -m 755 /var/prometheus/textfile
```

Run it once:

```ksh
doas /usr/local/sbin/mape-prometheus-metrics
cat /var/prometheus/textfile/mape.prom
```

Run it from cron:

```cron
* * * * * /usr/local/sbin/mape-prometheus-metrics >/dev/null 2>&1
```

## node_exporter

Serve the generated textfile with node_exporter's textfile collector:

```ksh
node_exporter --collector.textfile.directory=/var/prometheus/textfile
```

Prometheus scrape example:

```yaml
scrape_configs:
  - job_name: openbsd-mape
    static_configs:
      - targets:
          - 192.168.x.x:9100
```

Restrict access with PF so only the Prometheus server can scrape node_exporter.

## Metrics

The collector emits MAP-E and service health gauges:

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

It also emits local PF and queue metrics:

- `pf_states`
- `pf_halfopen_tcp`
- `pf_counter_total{counter="..."}`
- `pf_queue_packets_total{queue="..."}`
- `pf_queue_bytes_total{queue="..."}`
- `pf_queue_dropped_packets_total{queue="..."}`
- `pf_queue_dropped_bytes_total{queue="..."}`
- `pf_queue_length{queue="..."}`
- `pf_queue_limit{queue="..."}`

Finally, it emits `pfctl_exporter`-compatible metrics parsed from
`pfctl -vvs info`, `pfctl -vvs Interfaces`, `pfctl -Pvs rules`, and
`pfctl -vvs Tables`. These keep the upstream `pfctl_*` names and Prometheus
types, including `_total` suffixes for counters.

## Grafana

Import `grafana-map-e-ce-pfctl-dashboard.json` into Grafana and select the
Prometheus data source that scrapes the router from the dashboard's
`Data source` variable.

The dashboard includes:

- MAP-E CE control-plane health.
- node_exporter textfile freshness and scrape error checks.
- PF queue throughput, drops, and fill.
- pfctl-compatible PF rule, interface, table, state table, and counter panels.

Rate panels use `$rate_window`, defaulting to `5m`, instead of Grafana's
`$__rate_interval`. Keep `$rate_window` several times larger than the collector
refresh interval; `5m` works well for a once-per-minute cron job.

The dashboard intentionally uses a regular Grafana datasource variable named
`datasource` instead of import-time `__inputs`. This is more reliable when a
Grafana instance has multiple Prometheus datasources or when the dashboard is
provisioned from JSON. All panels, query variables, and ad hoc filters reference
`${datasource}`, so changing the `Data source` dropdown updates the whole
dashboard.

## Naming

Use `MAP-E CE` in prose for the Customer Edge MAP-E router role. Use
`map-e-ce` in filenames and dashboard UIDs. The daemon remains `maped`, and the
collector executable is `mape-prometheus-metrics`.

Metric prefixes are intentionally split:

- `maped_*`, `mape_*`, `dhcp6leased_*`, and `pppoe_*` are MAP-E/router health.
- `pf_*` are local compatibility metrics from this project.
- `pfctl_*` are compatible with the upstream `pfctl_exporter` metric names and
  types.

## License

The top-level project is ISC licensed. The metrics directory has its own
`LICENSE` because the pfctl-compatible metric names/parser and dashboard are
derived from Thomas Steen Rasmussen's
[`pfctl_exporter`](https://github.com/tykling/pfctl_exporter), published as the
BSD-3-Clause `pfctl-exporter` package. Keep `metrics/LICENSE` with redistributed
copies of this directory.
