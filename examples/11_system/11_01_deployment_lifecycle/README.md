# 11_01 Deployment lifecycle

Recover shared deployments after coordinator loss without using uncertain
capacity for replacement work.

## What you will learn

- Preserve Refs, committed events, and request identity through a partial drain.
- Wait for accepted Agent visibility before attaching a required binding.
- Run independent work while a disconnected source retains uncertain claims.
- Check cleanup and Core ownership in managed and attached modes.

## Read the code

Read [the Recorder and two topologies](subscriber.ex), then the
[test](../../../test/examples/11_system/11_01_deployment_lifecycle/deployment_lifecycle_test.exs).
The [shared scenario](../../../test/examples/support/system_lifecycle_scenario.ex)
contains the lifecycle assertions used by both system examples.
The [system fixture](../../../test/examples/support/system_lifecycle_case.ex)
starts four isolated peers, a real Bedrock journal, and shared Mnesia Agent storage.
It uses the [federation fixture](../../../test/examples/support/federation_lifecycle_case.ex),
[recovery fixture](../../../test/examples/support/journal_recovery_case.ex),
[journal barrier](../../../test/examples/support/journal_reply_loss.ex),
[location barrier](../../../test/examples/support/location_visibility_barrier.ex),
and [movement barrier](../../../test/support/movement_barrier.ex).
The [peer fixture](../../../test/support/cluster_case.ex) and
[Bedrock fixture](../../../test/support/bedrock.ex) check external resource cleanup.

## Run it

```sh
mise exec -- mix test test/examples/11_system/11_01_deployment_lifecycle --only example --seed 0
```

Expected result: two subscribers retain `baseline` through an interrupted drain
and coordinator recovery. A later drain becomes uncertain when its source is
disconnected. The independent allocation accepts work and receives an event.
After reconnection and explicit recovery, both original Refs receive `fresh`.
A previously stopped deployment stays stopped. All deployments then stop and
release their claims and channel components.

## Important behavior

The test holds a target after process creation but before public Ref visibility.
Cluster reports a pending lookup, no target mirror exists, and reconciliation
does not start a second subscriber. Another barrier holds the first completed
move's journal reply. Coordinator loss then causes actual Agent cleanup before
recovery restores the accepted state and original drain request.

During source disconnection, the test retains both source and target claims. It
restores links only among the remaining peers before it requests independent work.
An empty host allocation can reconcile its old owner only when direct host
evidence and the current journal show no prior claim that requires recovery.
The uncertain destination stays empty until source reachability returns.

The test checks prior Agent exits, current mirror component exits, released
claims, journal shutdown, and peer shutdown. Managed Core stops with Cluster.
Attached Core remains alive until the fixture explicitly stops it.

## Limits

This example uses static trusted BEAM peers. Bedrock runs on one control peer
with relaxed durability; this does not prove disk or replica failure recovery.
Mnesia stores Agent state separately and can report partition warnings during
the deliberate disconnect. The test does not write the isolated subscribers
during that interval. It does not prove arbitrary concurrent partition writes.
Publication remains best effort, without durable replay or continuous delivery
during movement. No provider resources, credentials, or external service are needed.

Previous: [08_04 Uncertain attachment](../../08_federation_lifecycle/08_04_uncertain_attachment/README.md) |
Next: [11_02 Provider lifecycle](../11_02_provider_lifecycle/README.md).
