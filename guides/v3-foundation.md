# V3 foundation

## Ownership boundaries

`jido_action` owns Actions and in-memory execution. `jido_signal` owns Signals.
`jido` owns Agents, AgentServer, Plugins, commit revisions, and persistence record
encoding. `jido_cluster` owns manager membership, keyed placement, and activation
lifetime across connected nodes. No sibling SDK repository is changed here.

The manager owns a Jido instance on each worker. Its namespace and key-derived
Agent IDs are stable across workers. Extra Agent options cannot replace identity,
registration, persistence, or restart settings. Each activation is temporary;
after a failure, the next manager operation must resolve ownership and restore
state before it runs more work.

## Storage

The Mnesia adapter implements `Jido.Persistence.Adapter` with binary keys and
values. Its compare-and-swap check and write occur in one transaction, including
creation of a missing key. It does not contain thread logs or checkpoint codecs.
The application creates and manages its Mnesia table and replicas.
Nested Mnesia transactions are rejected before a write, so an outer transaction
cannot undo a write after the adapter has reported success.

Shared storage is needed to retain committed state after owner-node loss.
`Jido.Persistence.ETS` is local storage. Moving a key that uses local storage can
lose its prior state. A successful cast is not proof that a Turn committed.

## Membership and faults

Only live managers join the placement group. Discovery-only nodes do not count
toward quorum. All participating managers must have the same configuration;
a mismatch rejects work before an Agent is started.

The manager stops a previous connected owner before a key starts on its new
placement node. Failed RPCs stop that operation. No automatic Signal retry occurs.
Quorum checks reject new work, and a local monitor stops activations within its
100 ms check interval after the membership view reports quorum loss. Shutdown
can take longer if an activation does not stop promptly.

This is a connected BEAM foundation. It does not fence a disconnected writer by
storage lease. A caller that writes directly through a returned pid bypasses
manager checks. Production partition guarantees require a later ownership and
fencing design, plus partition tests.

## Tests

Run all active tests from `jido_cluster`:

```sh
mise exec -- mix test.all
```

The suite checks:

- compatible V3 runtime versions;
- concurrent keyed starts and committed Agent revisions;
- recovery after stop or activation failure;
- manager shutdown and quorum rejection;
- Mnesia byte operations and concurrent compare-and-swap creation;
- multi-node routing and exclusion of nodes without managers;
- committed checkpoint recovery after owner-node loss;
- movement to a new connected owner and stop after a placement change;
- quorum-loss shutdown and configuration mismatch rejection.

The old 65-test V2 suite is retained in `archive/v2/test`. Its result is not a
V3 release gate. The normal run excludes peer and example tags. `mix test.all` includes both groups.

## Next work

Define durable ownership fencing before adding live replica transfer or
unconnected island leases. Then port periodic rebalancing, Bedrock, and Postgres
integration tests to the V3 byte storage and commit contracts. Restore normal
Hex requirements and package metadata before a release.
