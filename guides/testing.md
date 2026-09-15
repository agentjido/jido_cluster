# Local cluster testing

Run commands inside `jido_cluster`. Use the local V3 sibling dependencies and the pinned Erlang and Elixir tools.

```sh
mise exec -- mix deps.get
mise exec -- mix quality
mise exec -- mix test --seed 0
mise exec -- mix test.peer
mise exec -- mix test.examples
mise exec -- mix test.all
```

`mix test` excludes `:skip`, `:peer`, and `:example`. Unit tests do not start peer nodes. `mix test.peer` selects the distributed tests. `mix test.examples` selects the living examples. `mix test.all` includes peer and example tests but keeps explicit skips excluded. CI runs all three groups as separate steps.

## Node test setup

Use [ClusterCase](../test/support/cluster_case.ex) for local node tests:

```elixir
use JidoCluster.Test.ClusterCase

@tag cluster_nodes: 3
test "three-node behavior", %{cluster: cluster} do
  [first, second, third] = start_nodes(cluster, 3)
  assert cluster_call(cluster, first, Node, :connect, [second])
  assert third in cluster.nodes
end
```

The default is two nodes. Each test gets unique node names and a random cookie. Nodes bind to loopback, use two schedulers, and start through Erlang `:peer` with a standard I/O control channel. The parent test process does not need a distributed node name. Code paths are copied and `jido_cluster` starts on each node. Setup waits for the public connected-node view before it returns.

Each node has its own control channel. `cluster_call/6` can run from concurrent Tasks on different nodes without one shared call queue. Use `start_managers/3`, `await_members/4`, `shared_table/3`, and `stop_node/2` for the common operations. Peer boot and remote calls have bounded timeouts. Cleanup is registered before remote setup and uses process monitors to check that controllers stop, including after a failed test.

Use the public manager and AgentServer APIs for assertions. Wait for a state condition or monitor message. Do not use a fixed sleep as proof of completion. Replicated Mnesia RAM tables belong to each isolated node group and disappear when that group stops.

## Example tests

Use `JidoCluster.Test.ClusterCase, tag: :example` for examples that need nodes. These tests have only the `:example` tag. Do not also add `:peer`: ExUnit includes tags with OR semantics, which would put the example in the peer group.

Mirror the source folder under `test/examples/`. Run the example through its tagged test case. Keep example-only setup in `test/examples/support/`, including the [Topology case](../test/examples/support/topology_case.ex). Keep general node setup in `test/support/`. Both support folders compile in the test environment. See the [catalog](../examples/README.md) and [test instructions](../test/AGENTS.md).
