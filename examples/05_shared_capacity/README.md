# 05 Shared capacity

These examples use the named Cluster service to reserve Agent slots across
deployments. Read them in this order:

- [05_01 Last slot](05_01_last_slot/README.md): Two independent peer callers request the final slot. One deployment starts. The other request returns a capacity error.
- [05_02 Shared host](05_02_shared_host/README.md): Two deployments share one host. Stopping the first leaves the second Agent and its claim active.
- [05_03 Shared drain](05_03_shared_drain/README.md): A host drain moves both deployments and preserves their Refs and committed counts.
- [05_04 Transition capacity](05_04_transition_capacity/README.md): A drain starts no move when the target is full. The application stops a target occupant and retries the drain.
- [05_05 Independent progress](05_05_independent_progress/README.md): An interrupted drain retains its source and target claims. Work on a separate host still completes.

Run the group:

```sh
mise exec -- mix test test/examples/05_shared_capacity --only example --seed 0
```

The [worker](support/worker.ex) records a committed count. The
[test setup](../../test/examples/support/shared_capacity_case.ex) keeps node
setup separate from domain behavior. Tests use public claims, operation status,
Ref routing, core observations, and bounded telemetry barriers.

These examples use a memory control journal and replicated RAM Agent storage.
They do not prove durable restart, host creation, or capacity enforcement against
unmanaged processes. Previous group: [Deployment](../04_deployment/README.md).
