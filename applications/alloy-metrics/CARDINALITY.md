# Metrics cardinality cleanup (alloy-metrics)

Reusable pattern for trimming high-cardinality scrape noise when bringing
`alloy-metrics` up on a new cluster/overlay. First implemented on `use1`
(see `overlays/use1/configmap.yaml` for the live example).

Two independent levers — do **both**, for different reasons:

- **Lever A — bound the collector (memory).** Set resource requests/limits +
  `GOMEMLIMIT` on the alloy container. This is the real memory lever.
- **Lever B — drop junk series (ingest/storage hygiene).** Relabel-drop metrics
  no dashboard uses. This trims Mimir ingest/storage and the WAL, but only
  modestly reduces alloy RSS (heap is dominated by the *remaining* series).

> Reality check from use1: Lever B removed ~25k of ~360k series (~7%). Mimir
> ingest and WAL active-series dropped clearly; per-pod **RSS barely moved**
> (~900–960 MiB before and after). If your goal is lower alloy memory, Lever A
> does the work; Lever B is about not paying to store/query useless series.

---

## Lever A — bound the container

In the overlay `values.yaml`, under `alloy:` (the alloy chart container has **no
limits by default** — it will grow unbounded):

```yaml
alloy:
  resources:
    requests:
      cpu: 100m
      memory: 1Gi        # ~ steady-state working set; size from observed RSS
    limits:
      memory: 1536Mi     # hard cap (no CPU limit — don't throttle a scraper)
  extraEnv:
    - name: GOMEMLIMIT
      value: "1350MiB"   # ~88% of the memory limit; Go GC reclaims headroom
                         # before the hard cap. Keep it above live heap or GC thrashes.
```

Rule of thumb: `GOMEMLIMIT` ≈ 0.85–0.9 × memory limit, and the limit a bit
above observed warmed RSS. Don't set `GOMEMLIMIT` below the live Go heap
(`go_memstats_heap_inuse_bytes`) or you'll trade memory for GC CPU.

---

## Lever B — find the noise

Run against the Prometheus/Mimir datasource (use1 datasource uid: `mimir`).

1. Heaviest jobs by active series:
   ```promql
   topk(20, count by (job) ({__name__=~".+", job!=""}))
   ```
2. Break a heavy job down by metric name:
   ```promql
   topk(25, count by (__name__) ({job="<job>"}))
   ```

Two noise classes show up on essentially every cluster:

### B1. client-go / controller-runtime histograms

Any Go controller (longhorn, argocd, cnpg, operators…) exposes
`rest_client_*` and `workqueue_*` latency **histograms**. The `_bucket`
series are internal instrumentation nobody dashboards and explode cardinality
— on use1, longhorn-backend was **~10k of its ~16k series** from these alone.

Drop them with a dedicated relabel, and route the operator monitor scrapes
through it (they otherwise forward straight to remote_write):

```alloy
prometheus.relabel "drop_clientgo_histograms" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  rule {
    source_labels = ["__name__"]
    regex         = "(.*_)?(rest_client|workqueue)_.+_bucket"
    action        = "drop"
  }
}

prometheus.operator.podmonitors "primary" {
  forward_to = [prometheus.relabel.drop_clientgo_histograms.receiver]
  selector { match_labels = { instance = "primary" } }
}
prometheus.operator.servicemonitors "primary" {
  forward_to = [prometheus.relabel.drop_clientgo_histograms.receiver]
  selector { match_labels = { instance = "primary" } }
}
```

Keeps the `_count`/`_sum` and gauges; only the per-bucket series go.

### B2. unused cAdvisor `container_*` metrics

cAdvisor (the kubelet `/metrics/cadvisor` scrape) is usually the #1 source.
Drop the high-cardinality metrics no dashboard uses, on the relabel the
cAdvisor scrape already forwards to:

```alloy
prometheus.relabel "drop_high_cardinality" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  rule {
    source_labels = ["__name__"]
    regex = "container_(tasks_state|memory_failures_total|blkio_device_usage_total|network_(receive|transmit)_(errors|packets|packets_dropped)_total|memory_(swap|kernel_usage|total_active_file_bytes|total_inactive_file_bytes)|cpu_load(_d)?_average_10s|file_descriptors)"
    action = "drop"
  }
}
```

**Keep** (dashboards filter on these — do NOT add to the drop):
`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`,
`container_memory_usage_bytes`, `container_memory_rss`,
`container_network_{receive,transmit}_bytes_total`, `container_fs_*`,
`container_spec_*`, `container_fs_limit_bytes`.

On use1 this cut cAdvisor from **34,189 → 19,513 series** (~44%).

> Before extending the cAdvisor drop list, eyeball your dashboards — the safe
> list above is conservative. The bytes/working-set/spec series are load-bearing.

---

## Verifying a drop (important gotchas)

- **`count()` lags ~5 min.** After alloy stops writing a series, Mimir instant
  queries still return it for the staleness lookback (~5 min). Wait >5 min after
  the config reload, or check one specific dropped metric (returns *no data*
  immediately) instead of trusting an aggregate `count()`.
- **WAL active-series / RSS lag ~2h.** Dropped series stay in alloy's
  remote-write WAL head until the next truncation (~2h). So
  `prometheus_remote_write_wal_storage_active_series` and RSS don't move right
  away — re-check ~2h later. (use1: WAL 357k → 278k after truncation.)
- **Config hot-reloads, no restart.** The `alloy-config` ConfigMap is whole-dir
  mounted (not subPath), so the config-reloader sidecar picks up changes and
  reloads (logs `Reload triggered`). No pod roll needed for a config change.
- **Confirm the relabel is actually in the path:**
  `sum by (component_id) (rate(alloy_prometheus_relabel_metrics_processed[5m]))`
  — a non-zero rate on your drop component means series flow through it.

---

## Per-cluster checklist

1. `topk(20, count by (job) (...))` → identify heavy jobs.
2. Confirm B1/B2 noise with `topk(25, count by (__name__) ({job="..."}))`.
3. Add the two relabels; route operator monitors through `drop_clientgo_histograms`.
4. Set Lever A (`resources` + `GOMEMLIMIT`) sized from observed RSS.
5. Commit + let Argo sync (alloy-metrics is auto-sync + selfHeal — edit the
   overlay, don't `kubectl edit`).
6. Verify with the gotchas above (5-min `count()` lag, ~2h WAL lag).
