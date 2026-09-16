# Entities by domain key

Status: draft for review. `Jido.Cluster.Entity` admits a small, bounded set
of domain identities in a named Cluster scope. Each identity becomes one
root singleton core Topology. Entity demand and declared Topology demand use
the same journal, host claims, drain, and recovery path.

## Define an immutable workload

Give the workload a stable definition ID, an Agent module, and host labels.
A keyspace is optional. With a keyspace, the first element of each domain-key
tuple must equal it:

```elixir
alias Jido.Cluster.Entity

{:ok, device_workload} =
  Entity.new(
    definition_id: "devices/v1",
    keyspace: "devices",
    agent: MyApp.Device,
    requirements: ["compute"]
  )

device_key = {"devices", "meter-7"}
```

The version-one mapping includes the definition ID, keyspace, and key. It
creates a stable Topology ID. Core derives the Agent ID and Ref. A host name
or PID is not part of that identity. Keep the same definition and key after
a restart or move. The encoded source has a 180-byte limit so that the
Topology ID fits the core key limit. `Entity.limits/0` reports the mapping
version and bound.

## Find or activate a device

Use `ref/3` when you need its stable Ref without activation. Use `lookup/3`
to read only an accepted location. Use `ensure/3` to start an identity or
find its existing operation:

```elixir
{:ok, ref} = Entity.ref(MyApp.Cluster, device_workload, device_key)
{:ok, admitted} = Entity.ensure(MyApp.Cluster, device_workload, device_key)
{:ok, %{phase: :completed}} =
  Jido.Cluster.await(MyApp.Cluster, admitted.operation.id)

{:ok, location} = Entity.lookup(MyApp.Cluster, device_workload, device_key)
```

Two first requests for the same key pass through one serial admission and
one Agent activation. `lookup/3` does not start an Agent. A missing identity
returns `:not_found`; accepted but unready work returns `:pending`; an
unknown store or location returns `:uncertain`. Placement follows the
accepted host claim. A key hash does not start an Agent.

`Entity.call/5` combines admission, readiness wait, and one core Signal
call. For example:

```elixir
signal = Jido.Signal.new!(%{
  id: "meter-7-event-1",
  type: "devices.record",
  source: "/my-app/devices",
  data: %{}
})

{:ok, agent} = Entity.call(MyApp.Cluster, device_workload, device_key, signal)
```

The Agent must handle the Signal type. If activation is still pending when
the wait ends, `call/5` returns `:pending` and does not submit the Signal.
An uncertain activation returns `:uncertain`. A timeout after a Signal was
submitted can have an unknown business result; Cluster does not replay it.
Use application event IDs if your application needs duplicate control.

The [first activation](../examples/10_entities/10_01_first_activation/README.md)
and [movement](../examples/10_entities/10_02_entity_move/README.md) examples
show concurrent callers and a stable Ref with retained committed state.

## Limits

One scope admits at most eight running entity identities. Its journal holds
at most 16 deployments in total, including declared Topologies. A stopped
entity ID stays recorded and cannot start again in that scope. There is no
automatic eviction. The [mixed-demand example](../examples/10_entities/10_03_mixed_demand/README.md)
shows that declared Topology demand can use the last host slot first.

The eight-entity [local benchmark](../bench/entity_activation.exs) measures
activation time and journal size on one BEAM node with Mnesia RAM tables. It
does not establish production throughput or a large entity-service scale.
No entity path provides a replica, follower read, durable event
acknowledgement, or partition-safe replacement.
