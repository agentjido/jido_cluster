# Connected Topology placement

`Jido.Cluster.Scheduler` consumes root `cluster_worker` requirements from a core Topology. It selects configured connected hosts, checks namespace parity, admits the complete plan, and starts a manual core Controller. The Scheduler owns repair timing and drain policy. Core owns Agent execution, readiness, persisted targets, checkpoint encoding, and exact-node movement.

Start the same named Jido instance and namespace on each participating host. Configure shared persistence before activation if movement must retain state. Start the Scheduler on one control host after its Jido instance:

```elixir
{:ok, topology} = MyApp.Workers.new(id: "workers")

children = [
  {Jido.Cluster.Scheduler,
   jido: MyApp.Jido,
   topology: topology,
   hosts: [
     %{node: :"compute@host", labels: ["compute"], capacity: 2, available: true}
   ]}
]
```

Declare the worker requirements with `Jido.Cluster.Topology.Extension`. The host capacity is a non-negative integer slot budget for this Scheduler. It is not a global host limit. Use an application `:rest_for_one` boundary so the local Jido instance outlives the Scheduler. Do not operate its core Controller through a second repair or movement owner.

## Public operations

| Operation | Result |
| --- | --- |
| `status/1` | Phase, selected and desired placement, reserved slots, drain state, attempts, repairs, and errors |
| `whereis_agent/2` | Root singleton PID through the public core Controller, or nil |
| `update_hosts/2` | Validate inventory and request placement; busy operations reject changes |
| `drain/2` | Prove target capacity before accepting a connected-node drain |
| `reconcile/1` | Explicitly request a bounded operation; never replay an Agent Signal |
| `stop/1` | Stop owned core resources and wait for the public cleanup event; report cleanup failure or uncertainty |

Start and update calls do not acknowledge readiness. Observe `status: :ready` before using workers. A drained node appears in `drained` only after all selected placements are ready away from that node. Returned PIDs are temporary observations. Use core Refs when identity must survive a move.

## Results and limits

- `:blocked` means the configured requirements cannot be admitted or a selected host has a different namespace. Initial blocked admission starts no workers.
- `:placing` means one serialized operation is active. Current and desired slots are retained conservatively during movement.
- `:ready` means the core Controller reported readiness for the selected plan.
- `:uncertain` means source reachability or an operation result needs reconciliation. The runtime pauses automatic work. Planned slots are retained because an activation can already exist.

Worker exit on a connected host requests one bounded core repair operation. The default operation wait is 5000 ms; the membership/status poll interval is 250 ms. Core startup tasks have their own bounded settings in the Topology. An uncertain result requires an explicit request; there is no automatic retry loop.

A disconnected source cannot be replaced automatically. Core refuses an uncertain source retirement, and the Scheduler also checks reachability before submitting moves. Adding a spare host does not resolve the old source. Protected-write authority and a host-replacement contract remain design work.

Only root singleton Agents are admitted. Groups, includes, and Plugin-added Agents are rejected explicitly. Local Bus subscriptions constrain selection to the control node. Packing is deterministic and greedy. Inventory comes from the application, with connected membership used for availability. Release hashes and arbitrary resource compatibility are not checked.

Moves retain source and target slot claims until readiness. A packed swap without spare target slots is rejected with `{:transition_capacity, node}` before any move. The first slice does not plan a multi-stage evacuation to free those slots.

Scheduler ownership is local and temporary. Separate Schedulers do not share slot budgets. Operation state is not durable, and restart after accepted core placement targets is not covered. There is no global drain, automatic rebalance, dynamic provider, or durable writer lease.

Read the [placement examples](../examples/03_placement/README.md), [design lessons](../docs/design/01_package-purpose/lessons.md), and [test guide](testing.md).
