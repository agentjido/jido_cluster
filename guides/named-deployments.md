# Named deployments

Status: draft for review. This guide describes the implemented `v3-spike` API.

A named Cluster scope accepts root singleton Topologies. Cluster owns the
scope journal, host claims, and placement requests. Core Jido owns Agent
execution, state, and Refs. The same scope can also admit
[entity workloads](entities.md). Its capacity check applies to both forms
of demand.

## Define and start a scope

Define a Topology with `Jido.Cluster.Topology.Extension`. Its
`cluster_worker` label must match an available host. Define a Cluster module
for the application:

```elixir
defmodule MyApp.Workers do
  use Jido.Topology, name: "workers", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, MyApp.Worker, labels: ["compute"]
    end
  end
end

defmodule MyApp.Cluster do
  use Jido.Cluster, otp_app: :my_app
end
```

Start `MyApp.Cluster` under your application supervisor. This example uses
one local host and explicit memory storage. It is suitable for learning, not
for recovery after a service restart:

```elixir
children = [
  {MyApp.Cluster,
   namespace: "my-app/workers",
   journal: :memory,
   pools: [workers: [hosts: [
     %{node: node(), labels: ["compute"], capacity: 2, available: true}
   ]]]}
]
```

Without a `:jido` option, Cluster starts and owns a local core Jido instance.
With `jido: MyApp.Core`, it attaches to an already running core and leaves
that core running when the scope stops. The namespace must match. For a remote
worker, start a compatible named core and `Jido.Cluster.HostRuntime` on that
worker before you deploy. The service does not start a remote BEAM node. See
the [managed](../examples/04_deployment/04_01_managed_instance/README.md) and
[attached](../examples/04_deployment/04_02_attached_instance/README.md) examples
for full peer setup and cleanup.

## Admit work and call an Agent

`plan/2` checks supported placement without Agent activation. A deployment
request needs a token. Acceptance gives an operation ID; it does not prove
that the Agent is ready. Use a `Jido.Signal` that `MyApp.Worker` handles for
the final call:

```elixir
topology = MyApp.Workers.new!(id: "orders")
{:ok, _plan} = Jido.Cluster.plan(MyApp.Cluster, topology)

token = Jido.Cluster.request_id(MyApp.Cluster)
{:ok, operation} =
  Jido.Cluster.deploy(MyApp.Cluster, topology, request_id: token)

{:ok, %{phase: :completed}} =
  Jido.Cluster.await(MyApp.Cluster, operation.id, 5_000)

{:ok, ref} = Jido.Cluster.ref(MyApp.Cluster, "orders", :worker)
{:ok, result} = Jido.Cluster.call(MyApp.Cluster, ref, signal)
```

`ref/3` gives a stable core Ref. `lookup/2` reads its current accepted
location. A returned PID is a
temporary observation; route later calls through the Ref. Cluster submits
each `call/4` Signal once. It does not replay a timed-out call.

If a caller sends the same valid token with the same request again, Cluster
returns the recorded operation. A different request with that token returns
`:request_conflict`. `await/3` timeout does not cancel the operation. Read
`operation/2` and current `status/2` after a timeout. Current readiness is
separate from an older operation result.

## Drain and stop

`drain/3` excludes a host and reserves the full move before it starts. During
a move, Cluster charges the source and target claims until target readiness
and confirmed source cleanup. An unreachable source remains uncertain; spare
capacity does not give permission to start a second writer.

```elixir
host = node()
{:ok, move} =
  Jido.Cluster.drain(MyApp.Cluster, host,
    request_id: Jido.Cluster.request_id(MyApp.Cluster)
  )

{:ok, %{phase: :completed}} = Jido.Cluster.await(MyApp.Cluster, move.id)
```

The host remains excluded after a completed drain. Use `enable_host/3` with
a new token only when its active drain and unresolved claims are gone. Stop a
deployment with `stop/3`, then await confirmed cleanup. `claims/1` shows
reserved, active, and uncertain demand. A stop request does not erase its
deployment record from the bounded journal.

The current scope supports at most 16 deployment records, 32 canonical hosts,
and 64 claims. It retains up to 64 request bindings per epoch and 16 unresolved
operations. These are control limits, not machine resource measurements.
Read `status/1` for current limits and retention use. Read
[journal and recovery](recovery.md) before you choose durable storage.

The [deployment](../examples/04_deployment/README.md) and
[shared capacity](../examples/05_shared_capacity/README.md) examples run these
operations with real Agents on local peers. Only root singleton Agents are
admitted; groups, includes, and Plugin-added Agents are rejected.
