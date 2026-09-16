# 09_02 Lost acquire reply

Recover an uncertain acquisition by inspecting its saved step after abrupt owner
loss and a Bedrock restart.

## What you will learn

- Save the acquisition step before the provider can create a resource.
- Keep admission closed while inspection is unavailable.
- Adopt the original resource without a second acquisition call.

## Read the code

Read [the recorder and topology](topology.ex), then
[the test](../../../test/examples/09_host_providers/09_02_lost_acquire_reply/lost_acquire_reply_test.exs).
The [shared fixture](../../../test/examples/support/host_provider_case.ex) starts
real Bedrock, native peers, and the
[controlled provider](../../../test/support/host_provider.ex).

The [shared scenario functions](../../../test/examples/support/host_provider_scenario.ex)
contain the assertions used by the test runners.

## Run it

```sh
mise exec -- mix test test/examples/09_host_providers/09_02_lost_acquire_reply --include example --seed 0
```

Expected result: the provider creates one resource and loses its reply. The scope
record retains the attempted step with no resource handle. After abrupt owner
loss and repository restart, unavailable inspection keeps admission closed. A
later reconciliation adopts the exact resource. Replaying the original request
returns its completed operation. A subscriber then receives an event.

## Important behavior

The test kills the owner without termination callbacks and restarts the actual
Bedrock repository. It compares saved and recovered steps and resource records,
and checks that the provider received exactly one acquire call. Stop, release,
and checked process cleanup finish the run.

## Optional Docker run

Build the [prepared worker](../../../test/fixtures/docker_host/README.md) and set
`JIDO_CLUSTER_DOCKER_SOCKET` and `JIDO_CLUSTER_DOCKER_IMAGE` as described there.
Then select the explicit runner:

```sh
mise exec -- mix test test/examples/09_host_providers/09_02_lost_acquire_reply/docker_acceptance.exs --only example --seed 0
```

The [Docker runner](../../../test/examples/09_host_providers/09_02_lost_acquire_reply/docker_acceptance.exs)
uses the same scenario assertions, real Bedrock, and actual Docker observations.
Its [fixture](../../../test/examples/support/docker_provider_case.ex) uses a
native control node and independent Engine exec calls to the worker. Container
bootstrap can require explicit reconciliation of the original acquire step.
Cleanup requires empty discovery and authoritative absence of each recorded
step. An unavailable Engine or missing image invalidates the run.
This runner passes on the local Engine with the prepared worker image.

## Limits

The default runner tests Cluster recovery with a controlled provider and real
Bedrock. It does not simulate delayed external creation or prove Docker resource discovery,
networking, or deletion. The explicit Docker runner checks those effects.

Previous: [09_01 Acquired topology](../09_01_acquired_topology/README.md) |
Next: [09_03 Borrowed and incompatible hosts](../09_03_borrowed_and_incompatible/README.md)
