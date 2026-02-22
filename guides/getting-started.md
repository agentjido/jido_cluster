# Getting Started with Jido Cluster

This guide shows the smallest setup for running keyed Jido agents across multiple Elixir nodes.

## 1. Add dependency

```elixir
def deps do
  [
    {:jido_cluster, "~> 0.1.0"}
  ]
end
```

## 2. Start a distributed manager

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

## 4. Choose storage intentionally

- `Jido.Cluster.Storage.ETS`: local dev/test, no shared failover
- `Jido.Cluster.Storage.Mnesia`: shared, transactional revision checks
- `Jido.Cluster.Storage.Bedrock`: shared, transactional revision checks
- `Jido.Cluster.Storage.Postgres`: shared, SQL transaction + row lock checks

## 5. Test distributed behavior

Use the built-in distributed test patterns under `test/jido_cluster/distributed/` as references for:

- singleton race checks
- cross-node interactions
- join/leave rebalance behavior
- adapter conflict handling
