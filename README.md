# Jido Cluster

`jido_cluster` is a low-level clustered runtime for keyed Jido agents across
connected BEAM nodes.

It lets an application route work by logical key while the runtime handles
owner-node placement, singleton ownership, conservative rebalancing, and
storage-backed recovery. The deployable unit is your OTP release, not a
standalone `jido_cluster` service.

## Alpha Status

<!-- covers: jido_cluster.package.alpha_status -->
`jido_cluster` is alpha-quality and is being developed in the open while the
distributed ownership and failover model is still changing.

- Do not use this package for production systems yet.
- The cluster coordination and durability story is still actively being built.
- Bedrock-backed clustered scenarios are still under active integration work.
- Expect API changes, incomplete behaviors, and breaking changes.

<!-- covers: jido_cluster.package.public_namespace -->
Primary public namespace: `Jido.Cluster.*` (legacy `JidoCluster.*` remains available).

## Features

<!-- covers: jido_cluster.package.connected_beam_runtime -->
- Keyed singleton semantics per `{manager, key}`.
- Deterministic owner-node placement via rendezvous hashing.
- Cross-node `get/lookup/call/cast/stop` API by key.
- Conservative rebalancer (`30_000ms`, max `1` migration/tick by default).
- `Jido.Storage` adapters for ETS, Mnesia, Bedrock, and Postgres (raw Ecto).
- Multi-node ExUnit testing support using `ex_unit_cluster` and `:peer`.

## When To Use It

<!-- covers: jido_cluster.package.narrow_non_goals -->

Use `jido_cluster` when an app has stateful keyed work that should have one
active owner in a connected BEAM cluster:

- one workflow runner per `{tenant_id, workflow_id}`
- one coordinator per account, customer, device, or session
- one long-running agent per task or job key
- one recoverable process whose state can resume through shared storage

Do not use `jido_cluster` as a general multi-cluster fabric, semantic memory
system, quorum replication layer, or domain actor framework. Those higher-level
concerns should live above this package.

## Installation

Add `jido_cluster` to your dependencies:

```elixir
def deps do
  [
    {:jido_cluster, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

### Installation via Igniter

`jido_cluster` v0.1 does not yet provide an Igniter installer module.

## Quick Start

Start a distributed manager in your application's supervision tree:

```elixir
children = [
  {Jido.Cluster.InstanceManager,
   name: MyApp.ClusterManager,
   agent: MyApp.CounterAgent,
   storage: {Jido.Cluster.Storage.Mnesia, table: :my_cluster_table},
   rebalance: true,
   rebalance_interval_ms: 30_000,
   max_migrations_per_tick: 1}
]
```

Route operations by key from any connected node:

```elixir
signal = Jido.Signal.new!("inc", %{}, source: "/my_app")

{:ok, _pid} = Jido.Cluster.InstanceManager.get(MyApp.ClusterManager, "counter-1")
{:ok, agent} = Jido.Cluster.InstanceManager.call(MyApp.ClusterManager, "counter-1", signal)
:ok = Jido.Cluster.InstanceManager.cast(MyApp.ClusterManager, "counter-1", signal)
```

Inspect ownership and cluster stats:

```elixir
owner = Jido.Cluster.InstanceManager.owner_node(MyApp.ClusterManager, "counter-1")
stats = Jido.Cluster.InstanceManager.stats(MyApp.ClusterManager)
```

## Deployment Model

<!-- covers: jido_cluster.package.deployment_model -->

`jido_cluster` is embedded in an OTP application. Run the same release on
multiple connected BEAM nodes, and start the same `Jido.Cluster.InstanceManager`
configuration on each participating node.

Use a Phoenix app when HTTP, webhooks, WebSockets, LiveView, or admin endpoints
are the ingress. A controller or channel can build a `Jido.Signal` and route it
through `Jido.Cluster.InstanceManager.call/4`; the request may hit any node.

Use a headless OTP release when the ingress is a queue, PubSub topic, Kafka,
SQS, cron, sensors, or another internal event source. The worker consumes the
event and routes it through the same manager API.

In both cases, callers address logical keys, not pids or nodes.

## Ownership Contract

- Route clustered work through `Jido.Cluster.InstanceManager` by `{manager, key}`.
- One logical key has one active primary and at most one standby.
- Live-transfer mode is sync-only today. Configure `replication: %{replicas: 0, mode: :sync}` for primary-only placement or `replication: %{replicas: 1, mode: :sync}` for primary plus standby.
- Returned pids from `get/lookup` are short-lived observations of the current
  primary, not a durable cluster identity.
- `epoch` tracks ownership changes such as promotion and planned handoff.
- `seq` tracks the last acknowledged replicated update for the key.
- `owner_node/2` and `stats/1` reflect the current visible cluster view.

## Partition Policy

With `coordination_backend: :connected_beam` and `partition_policy: :freeze`,
`min_quorum_nodes` gates clustered work. When quorum is lost, managers reject
new work with `{:error, :cluster_unavailable}` and local ownership is stopped.
Live-transfer managers stop both local primaries and standbys so a minority
partition cannot continue serving or promote a standby later.

Freeze and unfreeze transitions emit telemetry under
`[:jido_cluster, :partition, :freeze | :unfreeze]`.

## Storage Adapters

- `Jido.Cluster.Storage.ETS`
  - Delegates to `Jido.Storage.ETS`
  - Local-only backend (`shared_backend? == false`)
- `Jido.Cluster.Storage.Mnesia`
  - Shared backend with transactional `expected_rev` checks
- `Jido.Cluster.Storage.Bedrock`
  - Shared backend with transactional append and revision checks
- `Jido.Cluster.Storage.Postgres`
  - Shared backend via raw Ecto SQL + row locking

## Rebalancing

- Deterministic leader: smallest node name in connected cluster view.
- Rebalancer only moves keys when storage backend is shared.
- ETS migrations are skipped and emit telemetry events.

## Experimental Bedrock Lease Mode

`coordination_backend: {:bedrock_lease, opts}` is an experimental disconnected
island mode. A local renewer refreshes active leases for idle local keys before
TTL expiry; if renewal fails or another holder owns the key, the local runtime
is stopped. Lease acquire, renew, release, expiry, stale rejection, and failure
paths emit telemetry under `[:jido_cluster, :lease, stage]`.

## Production Drill

- [Fly connected-cluster failover drill](guides/fly-multi-region-failover-demo.md)

The Fly guide is an advanced connected-BEAM/shared-storage drill. It is not a
general multi-cluster federation guarantee.

## Testing Multi-Node Behavior

The package includes distributed tests under `test/jido_cluster/distributed/` that use:

- `ex_unit_cluster` for same-test-run node orchestration
- `:peer` for low-level distributed smoke tests

Run tests with:

```bash
mix test
```

## Development

```bash
mix setup
mix spec.init
mix spec.verify --debug
mix spec.check --no-run-commands
mix quality
mix test
```

`specled.dev` is installed as a dev/test tool via `spec_led_ex`. The `.spec/`
workspace is the current-truth contract layer for the evolving `Jido.Cluster.*`
runtime and should be updated alongside meaningful API, topology, or scenario
changes.

## License

Apache-2.0
