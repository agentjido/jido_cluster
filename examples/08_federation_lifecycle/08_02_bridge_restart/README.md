# 08_02 Bridge restart

Repair a failed channel while the subscriber Agent stays at its accepted location.

## What you will learn

- Separate local publication acceptance from remote delivery.
- Rebuild declared bindings with explicit `reconcile/1`.
- Retain the Agent PID, Ref, binding identity, and capacity claims during repair.

## Read the code

Read [the Recorder and topology](subscriber.ex), then the
[test](../../../test/examples/08_federation_lifecycle/08_02_bridge_restart/bridge_restart_test.exs).
The [lifecycle fixture](../../../test/examples/support/federation_lifecycle_case.ex)
starts three peers with a real Bedrock journal and shared Mnesia Agent storage.
It uses the [peer fixture](../../../test/support/cluster_case.ex) and
[Bedrock fixture](../../../test/support/bedrock.ex).

## Run it

```sh
mise exec -- mix test test/examples/08_federation_lifecycle/08_02_bridge_restart --only example --seed 0
```

Expected result: the Agent receives `before`. An `interrupted` publication has
local acceptance and one pending export when its bridge fails. The mirror
confirms export-task cleanup. Explicit reconciliation replaces the mirrors and
connections, retains the same Agent and claims, and increases the binding
revision. The Agent then receives `after`; `interrupted` is not replayed. The
original deployment operation remains completed.

## Important behavior

Repair records intent and confirms exact mirror cleanup before it creates the
next revision. It checks the current Controller and Agent PIDs but does not
start, stop, reconcile, or move an Agent. An unknown cleanup result prevents
replacement. Deployment status keeps Agent readiness separate from binding
readiness and shows the pending transition. `reconcile/1` returns acceptance;
wait for `recovering: false` and current binding readiness.

Stop checks current Agent and mirror component exits and releases all claims.
The test also checks old component, export-task, transport fixture, Core,
journal, and peer cleanup.

## Limits

The [recording transport](../../../test/support/federation/recording_transport.ex)
holds the interrupted export before remote submission. This creates a precise
failure point; it does not prove a real network failure or remote acceptance.
The `before` and `after` publications use real connected transport. General
interruption can leave remote delivery unknown. Repair does not replay memory
events or promise continuous delivery.

Bedrock uses one peer with relaxed filesystem durability. The example does not
prove replica failure, machine failure, or cleanup after abrupt mirror process
loss. Unknown journal outcomes still require full activation recovery. No
credentials or external service are needed.

Previous: [08_01 Subscription move](../08_01_subscription_move/README.md).
Next: [08_03 Shared cleanup](../08_03_shared_cleanup/README.md).
