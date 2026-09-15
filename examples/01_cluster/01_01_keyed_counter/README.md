# 01_01 Keyed counter

Two callers need to update the same logical counter. The manager routes their Signals to one owner. A replicated Mnesia table stores each committed checkpoint. If that owner stops, the surviving node restores the counter and its commit revision.

## Learn

- Define a small V3 Agent with a typed command, a default amount, and a scoped Signal source.
- Route all writes through `InstanceManager.call`, using the same logical key.
- Restore the committed state and revision after owner loss.
- Stop all local Erlang nodes when the run ends, including when an assertion fails.

## Reading order

1. [counter.ex](counter.ex): the Agent and generated Signal helpers.
2. [Test cases](../../../test/examples/01_cluster/01_01_keyed_counter/keyed_counter_test.exs): two-node setup, routing, recovery, and public API assertions.
3. [Shared node test setup](../../../test/support/cluster_case.ex): node creation and bounded cleanup.

## Run

Use the sibling V3 dependencies listed in the [package README](../../../README.md). No credentials are needed. Run from `jido_cluster`:

```sh
mise exec -- mix deps.get
mise exec -- mix test.examples
```

For this test file only:

```sh
mise exec -- mix test test/examples/01_cluster/01_01_keyed_counter/keyed_counter_test.exs --only example --seed 0
```

Each test creates two nodes on loopback with a unique cookie. Both nodes start the same manager configuration. The routing case adds 1 from the first node and 2 from the second node. The recovery case stops the owner, waits for membership to change, restores count 3 at revision 2, and adds 1.

Expected assertions:

- Both callers reach the same owner and produce count 3 at revision 2.
- A zero amount is rejected without a new commit.
- After owner loss, the saved count is 3 at revision 2.
- The next valid command produces count 4 at revision 3.
- All peer controller processes stop during cleanup.

## Limits and cleanup

This example uses replicated RAM copies. It retains state while one node remains; it does not retain state after both nodes stop. Test cleanup is registered before remote application setup and waits for each peer controller to stop, including after a failed assertion.

The manager permits one surviving node (`min_quorum_nodes: 1`, the default) to show recovery. This does not prove partition safety, durable writer leases, disk recovery, or production quorum policy. Signals are not retried after an unknown result. See the [foundation contract](../../../guides/v3-foundation.md) before using the runtime in a deployment.

Return to [01 Cluster](../README.md) or the [catalog](../../README.md).
