# Getting Started with Jido Cluster

<!-- covers: jido_cluster.bootstrap.getting_started_guide -->
<!-- covers: jido_cluster.storage.getting_started_storage_choices -->

This guide shows the smallest setup for running keyed Jido agents across
multiple connected Elixir nodes.

## 1. Add dependency

```elixir
def deps do
  [
    {:jido_cluster, "~> 0.1.0"}
  ]
end
```

## 2. Start a clustered manager

Add the manager to your application's supervision tree. The deployable unit is
your OTP release, not a standalone `jido_cluster` service.

```elixir
children = [
  {Jido.Cluster.InstanceManager,
   name: MyApp.ClusterManager,
   agent: MyApp.CounterAgent,
   storage: {Jido.Cluster.Storage.Mnesia, table: :my_cluster_table},
   rebalance: true}
]
```

## 3. Route work by key

```elixir
signal = Jido.Signal.new!("inc", %{}, source: "/my_app")

{:ok, _pid} = Jido.Cluster.InstanceManager.get(MyApp.ClusterManager, "counter-1")
{:ok, agent} = Jido.Cluster.InstanceManager.call(MyApp.ClusterManager, "counter-1", signal)
```

## 4. Choose a deployment shape

Phoenix app:

- Use when HTTP, webhooks, WebSockets, LiveView, or admin endpoints trigger
  agent work.
- Put `Jido.Cluster.InstanceManager` in the Phoenix supervision tree.
- Route controller, channel, or LiveView events through the manager by key.

Headless OTP app:

- Use when queues, PubSub, Kafka, SQS, cron, sensors, or internal events trigger
  agent work.
- Put `Jido.Cluster.InstanceManager` in the worker release supervision tree.
- Route consumed events through the manager by key.

Every participating node should run the same manager configuration.

## 5. Choose storage intentionally

- `Jido.Cluster.Storage.ETS`: local dev/test, no shared failover
- `Jido.Cluster.Storage.Mnesia`: shared, transactional revision checks
- `Jido.Cluster.Storage.Bedrock`: shared, transactional revision checks
- `Jido.Cluster.Storage.Postgres`: shared, SQL transaction + row lock checks

## 6. Choose live-transfer replication intentionally

Live-transfer mode currently supports synchronous acknowledgement semantics:

- `replication: %{replicas: 0, mode: :sync}` starts only the primary runtime.
- `replication: %{replicas: 1, mode: :sync}` starts a primary and one standby.

Async replication mode is rejected for live-transfer managers until its
acknowledgement contract is implemented.

## 7. Test distributed behavior

Use the built-in distributed test patterns under `test/jido_cluster/distributed/` as references for:

- singleton race checks
- cross-node interactions
- join/leave rebalance behavior
- adapter conflict handling
