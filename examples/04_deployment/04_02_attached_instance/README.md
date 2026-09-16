# 04_02 Attached instance

The application retains core while Cluster owns deployment cleanup.

## What you will learn

- Separate accepted operation state from current Agent readiness.
- Use core topology and Ref identity through a named Cluster instance.
- Check process cleanup with public APIs.

## Read the code

Read [the topology and instance](topology.ex), then the shared
[Worker](../support/worker.ex), then the test.

## Run it

```sh
mise exec -- mix test test/examples/04_deployment/04_02_attached_instance --include example --seed 0
```

Expected result: The test deploys on a peer and calls by Ref. Cluster shutdown terminates its Agent and retains the external core.

## Important behavior

Start compatible core and `Jido.Cluster.HostRuntime` on each remote host before
deployment. `journal: :memory` is an explicit development choice. Stop retains
uncertain cleanup as an incomplete operation. A Signal call is never replayed.

## Limits

This example uses root singletons, static connected hosts, and an explicit
memory journal. It proves only its stated lifecycle. The named service also
supports durable journals and shared drain; see the later examples. A
disconnected host is not proof of a dead Agent. This test does not prove
persistent restart, provider cleanup, or partition safety.

## Files

- [Source](topology.ex)
- [Worker](../support/worker.ex)
- [Tests](../../../test/examples/04_deployment/04_02_attached_instance/attached_instance_test.exs)
- [Peer setup](../../../test/examples/support/deployment_case.ex)

Previous: [Managed instance](../04_01_managed_instance/README.md) | Next: [Request identity](../04_03_request_identity/README.md)
