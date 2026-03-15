# Jido Cluster

`jido_cluster` provides a minimal distributed runtime for keyed Jido agents across multiple BEAM nodes.

It layers cluster ownership, routing, and conservative rebalancing around `Jido.Agent.InstanceManager`, plus
shared persistence adapters for multi-node recovery.

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
- Global singleton semantics per `{cluster, jido_instance, id}` key.
- Deterministic owner-node placement via rendezvous hashing.
- Cross-node `get/lookup/call/cast/stop` API by key.
- Conservative rebalancer (`30_000ms`, max `1` migration/tick by default).
- `Jido.Storage` adapters for ETS, Mnesia, Bedrock, and Postgres (raw Ecto).
- Multi-node ExUnit testing support using `ex_unit_cluster` and `:peer`.

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

Start a distributed manager in your supervision tree:

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

## Ownership Contract

- Route clustered work through `Jido.Cluster.InstanceManager` by `{manager, key}`.
- One logical key has one active primary and at most one standby.
- Returned pids from `get/lookup` are short-lived observations of the current
  primary, not a durable cluster identity.
- `epoch` tracks ownership changes such as promotion and planned handoff.
- `seq` tracks the last acknowledged replicated update for the key.
- `owner_node/2` and `stats/1` reflect the current visible cluster view.

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

## Production Drill

- [Fly multi-region failover demo](guides/fly-multi-region-failover-demo.md)

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
