# Jido Cluster V3

`jido_cluster` is an alpha cluster runtime for keyed Jido V3 Agents on connected
BEAM nodes. This branch is a local integration foundation. It is not ready for
a Hex release or production use.

## Local setup

Use the sibling V3 checkouts:

- `../jido` on `release/v3`
- `../jido_action` on `release/v3`
- `../jido_signal` with a compatible V3 version

`mix.exs` uses these paths with `override: true`. No environment switch or V2
fallback is used. Restore Hex requirements before a package release.

```sh
mise install
mise exec -- mix setup
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test --seed 0
mise exec -- mix quality
```

The `.tool-versions` file selects OTP 28 and Elixir 1.19. The normal test run excludes peer and example tests. Use `mix test.all`
to run all active tests. CI checks out the sibling V3 repositories before it builds.

## Start a manager

Start the same configuration on each worker node:

```elixir
children = [
  {Jido.Cluster.InstanceManager,
   name: MyApp.ClusterManager,
   agent: MyApp.CounterAgent,
   namespace: "my-app/counters",
   min_quorum_nodes: 2,
   persistence: {Jido.Cluster.Storage.Mnesia, table: :cluster_agent_records}}
]
```

Create the Mnesia schema and replicated table before manager startup. The table
must be a `set` with attributes `[:key, :value]` and `local_content: false`.
The application selects RAM or disk copies and any Mnesia majority policy.
For local tests, use `Jido.Persistence.ETS` instead of shared storage.

Route Signals by logical key:

```elixir
alias Jido.Cluster.InstanceManager

signal = Jido.Signal.new!("inc", %{}, source: "/my-app")
{:ok, agent} = InstanceManager.call(MyApp.ClusterManager, {:account, "one"}, signal)
{:ok, pid} = InstanceManager.lookup(MyApp.ClusterManager, {:account, "one"})
snapshot = Jido.AgentServer.snapshot(pid)
# %{agent: %Jido.Agent{}, state_version: revision}
```

`call/4` returns the committed V3 Agent. `cast/3` acknowledges enqueue only.
`stop/2` stops the activation and keeps its record for recovery. A later `get/3`
restores the checkpoint and commit revision when persistence is configured.

## Foundation contract

- Only nodes with a live manager participate in placement and quorum checks.
- Rendezvous hashing chooses the current placement node for `{manager, key}`.
- A connected-cluster lock serializes manager operations for each key.
- Before work moves to a new connected owner, its prior activation is stopped.
- Jido owns Action execution, Agent state, checkpoint encoding, and commit writes.
- Quorum loss rejects new manager work and stops local activations.
- Returned pids are temporary observations. Route writes through the manager.
- A timeout can have an unknown result. Signals are never retried automatically.

This connected BEAM view and lock do not provide a durable writer lease.
Configure quorum for the fixed deployment and shared storage for recovery.
The first foundation does not support live replicas, disconnected island leases,
Postgres cluster adapters, or automatic periodic rebalancing. Old V2 options are
rejected rather than silently accepted.

See [the V3 foundation guide](guides/v3-foundation.md) for test coverage and next
steps. The previous V2 implementation and tests are retained under `archive/v2/`.
They are not compiled, tested, or packaged as current V3 code.

See the [living examples](examples/README.md) and [local node testing guide](guides/testing.md).

The [design folder](docs/design/README.md) defines the proposed package purpose and its boundary with core V3. Proposals are separate from the current runtime contract.
