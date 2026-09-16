# 04_01 Managed instance

Cluster owns core and settles remote Agent cleanup before core stops.

## What you will learn

- Separate accepted operation state from current Agent readiness.
- Use core topology and Ref identity through a named Cluster instance.
- Check process cleanup with public APIs.

## Read the code

Read [the topology and instance](topology.ex), then the shared
[Worker](../support/worker.ex), then the test.

## Run it

```sh
mise exec -- mix test test/examples/04_deployment/04_01_managed_instance --include example --seed 0
```

Expected result: The test plans without activation, deploys on a peer, calls by Ref, and stops the service. Both the remote Agent and managed core terminate.

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
- [Tests](../../../test/examples/04_deployment/04_01_managed_instance/managed_instance_test.exs)
- [Peer setup](../../../test/examples/support/deployment_case.ex)

Previous: [example catalog](../../README.md) | Next: [Attached instance](../04_02_attached_instance/README.md)
