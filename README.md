# Jido Cluster

`jido_cluster` provides a minimal distributed runtime for keyed Jido agents across multiple BEAM nodes.

It layers cluster ownership, routing, and conservative rebalancing around `Jido.Agent.InstanceManager`, plus
shared persistence adapters for multi-node recovery.

Primary public namespace: `Jido.Cluster.*` (legacy `JidoCluster.*` remains available).

## Features

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
mix quality
mix test
```

## License

Apache-2.0
