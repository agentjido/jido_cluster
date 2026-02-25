# Fly Multi-Region Failover Demo

This guide scaffolds a production-style demo for Jido Cluster runtime stability on Fly.io.

Goal: run one logical `Jido.Cluster.InstanceManager` across multiple Fly regions, then hard-stop one region and demonstrate that keyed agent operations continue from surviving regions.

## Use Case

Assume an event-processing control plane where each tenant key must have one logical singleton agent:

- key: `{tenant_id, workflow_id}`
- guarantee: singleton semantics for each key across regions
- requirement: region outage should not take tenant processing offline

## Topology

Baseline demo topology:

- Regions: `iad`, `ord`, `lax`
- App machines: `2` per region
- Shared storage: `Jido.Cluster.Storage.Postgres` (recommended for cross-region durability)
- Cluster formation: `dns_cluster` over Fly private DNS

## App Scaffold

In your host app supervision tree, configure one distributed manager:

```elixir
children = [
  MyApp.Repo,
  {Jido.Cluster.InstanceManager,
   name: MyApp.ClusterManager,
   agent: MyApp.CounterAgent,
   storage: {Jido.Cluster.Storage.Postgres, repo: MyApp.Repo},
   rebalance: true,
   rebalance_interval_ms: 10_000,
   max_migrations_per_tick: 5,
   cluster_formation: [
     dns_cluster: [query: "#{System.fetch_env!("FLY_APP_NAME")}.internal"]
   ]}
]
```

Set distributed release env vars on Fly:

- `RELEASE_DISTRIBUTION=name`
- `RELEASE_NODE=<app>@${FLY_PRIVATE_IP}`
- `RELEASE_COOKIE=<shared-cookie>`

## Demo Endpoints (Scaffold)

Expose minimal demo endpoints in the host app:

- `POST /demo/keys/:id/inc` -> routes `Jido.Cluster.InstanceManager.call/4`
- `GET /demo/keys/:id/owner` -> returns `owner_node/2`
- `GET /demo/cluster/stats` -> returns `stats/1`

These three endpoints are enough to show pre-failure health, failover behavior, and post-failure stability.

## Fly Deployment Drill

1. Create and deploy app in three regions.
2. Warm a stable set of keys via `POST /demo/keys/:id/inc`.
3. Record current owners via `GET /demo/keys/:id/owner`.
4. Kill all machines in one region (example: `ord`).
5. Continue calling `POST /demo/keys/:id/inc` from a surviving region.
6. Verify key owners/stats converge on surviving regions.

Example commands:

```bash
fly apps create my-jido-demo
fly secrets set RELEASE_COOKIE=<cookie> -a my-jido-demo
fly deploy -a my-jido-demo

fly scale count 2 --region iad -a my-jido-demo
fly scale count 2 --region ord -a my-jido-demo
fly scale count 2 --region lax -a my-jido-demo

fly machine list -a my-jido-demo
# stop all machines in ord
fly machine stop <machine-id-1> -a my-jido-demo --signal SIGKILL
fly machine stop <machine-id-2> -a my-jido-demo --signal SIGKILL
```

## What "Recovery" Means in This Demo

Recovery success criteria:

- no global outage: `/demo/keys/:id/inc` continues to return success
- key continuity: a key previously owned in the failed region can be resolved from a surviving region
- cluster continuity: `/demo/cluster/stats` remains healthy and converges after node loss
- observability: migration/failure telemetry is emitted during convergence

Attach telemetry to:

- `[:jido_cluster, :rebalancer, :migration, :start]`
- `[:jido_cluster, :rebalancer, :migration, :success]`
- `[:jido_cluster, :rebalancer, :migration, :failure]`
- `[:jido_cluster, :rebalancer, :migration, :skipped]`

## Features to Add Next

To strengthen the runtime stability story further:

1. Region-aware ownership policy: prefer in-region owners while preserving deterministic fallback.
2. Failure detector hooks: explicit node health signal integration to shorten failover reaction time.
3. Fast handoff API: proactive key handoff before planned region drains.
4. Drill automation: a `mix` task that runs a repeatable chaos drill and emits a pass/fail report.
5. Stability SLO metrics: p95 recovery latency and migration success rate exported per region.

## Local Validation in This Repo

For a local approximation of this drill, run distributed tests under:

- `test/jido_cluster/distributed/`

This repo now includes a region-failover recovery test scaffold to model the same behavior without Fly.
