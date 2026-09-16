# Federated Signals

Status: draft for review. Federation is for declared channels on connected
BEAM hosts. It gives bounded best-effort publication. It does not confirm
that a remote Agent executed an event.

## Declare a channel and subscriber

Use `Jido.Cluster.Topology.Extension` on the Topology. The channel lists the
Signal types it accepts. A root Agent subscribes by its declaration key:

```elixir
defmodule MyApp.Orders do
  use Jido.Topology, name: "orders", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, MyApp.OrderListener, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["orders.changed"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end
```

The subscriber Agent must handle `orders.changed` through its normal Jido
route. The channel identity includes the namespace, Topology ID, and channel
key. A second Topology or namespace has a separate channel. Core local Bus
subscriptions stay local. Cluster mirrors only the declared channel on the
control host and interested worker hosts.

A required subscription is part of deployment readiness. Cluster attaches
the declared core Ref to the accepted ready Agent. An optional subscription
can use `required: false`; its missing attachment remains visible but does
not block required readiness. Read the
[interested-host example](../examples/07_federation/07_01_interested_hosts/README.md)
for a complete Agent route and a three-node test.

## Publish and inspect

Publish through the named Cluster scope after the deployment is ready:

```elixir
signal = Jido.Signal.new!(%{
  id: "orders-change-1",
  type: "orders.changed",
  source: "/my-app/orders",
  data: %{order_id: "order-1"}
})

{:ok, receipt} = Jido.Cluster.publish(MyApp.Cluster, "orders", :events, signal)
{:ok, federation} = Jido.Cluster.federation_status(MyApp.Cluster, "orders")
{:ok, deployment} = Jido.Cluster.status(MyApp.Cluster, "orders")
```

The publication gate checks type and capacity before it puts the Signal in
the local federation mailbox. A success receipt reports local acceptance,
outbound submission, and interested targets. It is not a receipt from each
Agent. A timeout can leave the publication result uncertain. Cluster never
replays the business event. A repeated call with the same Signal creates a
new export identity; Signal ID reuse does not make the call idempotent.

Only `publish/5` exports an event. A local Bus publication and a received
import do not export it again. The transport preserves the original Signal
fields and suppresses a repeated export identity for a bounded time. The
[envelope example](../examples/07_federation/07_02_envelope_and_loops/README.md)
shows these checks.

## Movement and health

A managed drain records binding retirement, removes the source binding, moves
the core Agent, and attaches the target binding after Agent readiness.
`status/2` keeps Agent readiness and binding readiness separate. A completed
old operation does not prove that the current bridge is healthy. Use
`federation_status/2` to see binding and transport health. Explicit bridge
repair keeps the accepted Agent and its claims; it does not create a second
Agent. Read the [lifecycle examples](../examples/08_federation_lifecycle/README.md)
for movement, repair, shared cleanup, and an uncertain attachment.

Configure bounded queues with the scope's `federation` option. For example,
`federation: [outbound_slots: 8, inbound_slots: 8]` sets eight slots in each
direction. The defaults allow a 16 KiB envelope, 32 slots and 512 KiB in
each direction, 32 participating hosts, and 1024 duplicate identities for
60 seconds. These limits do not include Agent mailboxes or local Bus
publishers. Read the [placement guide](federated-signals.md)
for the full limit and failure contract.
