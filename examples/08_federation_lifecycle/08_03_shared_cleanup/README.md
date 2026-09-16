# 08_03 Shared cleanup

Stop one deployment without removing another deployment’s bindings or native transport.

## What you will learn

- Check exact Agent, binding, mirror, and sender cleanup.
- Retain another deployment's live components and shared BEAM connection.

## Read the code

Read [the Recorder and topology](subscriber.ex), then the
[test](../../../test/examples/08_federation_lifecycle/08_03_shared_cleanup/shared_cleanup_test.exs).
The [lifecycle fixture](../../../test/examples/support/federation_lifecycle_case.ex)
uses the [peer fixture](../../../test/support/cluster_case.ex), a
[real Bedrock journal](../../../test/support/bedrock.ex), and shared Mnesia Agent storage.

## Run it

```sh
mise exec -- mix test test/examples/08_federation_lifecycle/08_03_shared_cleanup --only example --seed 0
```

Expected result: the test places two subscribers on the same worker. Both receive an event through
native transport. After the first deployment stops, its Agent, mirrors, bindings,
and sender processes have exited. The second deployment keeps the exact Agent,
mirror and component PIDs, and claim. The shared BEAM connection remains present,
and a fresh event reaches the second Agent. Final stop checks all remaining cleanup.

## Important behavior and limits

Each deployment owns separate channel mirrors and sender processes. The native
BEAM connection is shared by the VMs; deployment cleanup never disconnects it.
There is no shared application sender object that needs a reference count.
This example proves two deployments on one pair of hosts, not arbitrary scale.
Delivery remains best effort. Bedrock runs on one peer with relaxed durability.
No credentials or external service are needed. The fixture checks Core, journal,
and peer cleanup after deployment cleanup.

Previous: [08_02](../08_02_bridge_restart/README.md).
Next: [08_04](../08_04_uncertain_attachment/README.md).
