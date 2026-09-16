# 07_01 Interested hosts

Deliver an event to the declared subscriber while other deployments and namespaces remain isolated.

## Read the code

Read [the Recorder, topology, and service](events.ex), then the
[test](../../../test/examples/07_federation/07_01_interested_hosts/interested_hosts_test.exs).
The topology puts its listener on a `compute` host and binds it to `:events`.
The test deploys two topology IDs in one namespace and the same first ID in a
second namespace. This separates deployment and namespace isolation.

Setup uses the [example fixture](../../../test/examples/support/federation_case.ex)
and [peer fixture](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/07_federation/07_01_interested_hosts --only example --seed 0
```

## Expected result

A publication on control host A names only subscribed host B as its remote
target. B commits the original Signal ID, type, source, and data once in the
observed batch. C has no mirror for that channel. Neither isolated Bus receives
the event. Export completion and normal Agent command replies act as barriers
before the tests inspect isolated state.

## Boundaries and cleanup

The test waits for required binding readiness before publication. It stops each
deployment and checks mirror components, Agents, and claims. It then stops the
instances, host guards, and Cores; the peer fixture checks node exit.

This is a fixed-host best-effort example. It does not prove exactly-once delivery,
durable event storage, recovery after a machine failure, or continuous delivery
during movement. The Recorder keeps a small test history in memory.

Previous: [06 Journal recovery](../../06_journal_recovery/README.md) | Next: [07_02 Envelope and loops](../07_02_envelope_and_loops/README.md)

Return to [07 Federation](../README.md).
