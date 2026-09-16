# 09_01 Acquired topology

Acquire a compatible host before deployment, then retain it until its Agent and
federation claims are released.

## What you will learn

- Provider readiness precedes runtime admission and deployment readiness.
- A release request closes admission but retains a host with active claims.
- Stop and reconciliation complete the original release request.

## Read the code

Read [the recorder and topology](topology.ex), then
[the test](../../../test/examples/09_host_providers/09_01_acquired_topology/acquired_topology_test.exs).
The [shared fixture](../../../test/examples/support/host_provider_case.ex) configures
Core, a Bedrock journal, shared Mnesia checkpoints, and the
[controlled provider](../../../test/support/host_provider.ex).

The [shared scenario functions](../../../test/examples/support/host_provider_scenario.ex)
contain the assertions used by the test runners.

## Run it

```sh
mise exec -- mix test test/examples/09_host_providers/09_01_acquired_topology --include example --seed 0
```

Expected result: planning fails before acquisition. After acquisition, a declared
subscriber commits an event. Release stays uncertain while its claim remains,
and the subscriber can still commit another event. Stop removes the Agent and
all recorded channel processes. Reconciliation completes the same release request
and Bedrock records the released resource identity.

## Important behavior

The test checks the provider call log before stop: no release effect is allowed.
It then checks empty claims, empty provider inventory, and process cleanup. A
provider release reply alone is insufficient; inspection must confirm absence.

## Optional Docker run

Build the [prepared worker](../../../test/fixtures/docker_host/README.md) and set
`JIDO_CLUSTER_DOCKER_SOCKET` and `JIDO_CLUSTER_DOCKER_IMAGE` as described there.
Then select the explicit runner:

```sh
mise exec -- mix test test/examples/09_host_providers/09_01_acquired_topology/docker_acceptance.exs --only example --seed 0
```

The [Docker runner](../../../test/examples/09_host_providers/09_01_acquired_topology/docker_acceptance.exs)
uses the same scenario assertions, real Bedrock, and actual Docker observations.
Its [fixture](../../../test/examples/support/docker_provider_case.ex) uses a
native control node and independent Engine exec calls to the worker. Container
bootstrap can require explicit reconciliation of the original acquire step.
Cleanup requires empty discovery and authoritative absence of each recorded
step. An unavailable Engine or missing image invalidates the run.
This runner passes on the local Engine with the prepared worker image.

## Limits

The default provider is controlled test infrastructure. Its inventory is in memory, while
the scope journal uses real Bedrock. It does not terminate a VM or container; the
test separately stops and checks the native runtime processes. The explicit
Docker runner checks creation, networking, and deletion of a real container.

Previous: [08_04 Uncertain attachment](../../08_federation_lifecycle/08_04_uncertain_attachment/README.md) |
Next: [09_02 Lost acquire reply](../09_02_lost_acquire_reply/README.md)
