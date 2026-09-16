# 09_03 Borrowed and incompatible hosts

Retain borrowed infrastructure after stop, and refuse Agent admission when an
owned worker has the wrong namespace.

## What you will learn

- Borrowed acquisition inspects existing capacity without creating it.
- Borrowed release retains the resource and its runtime.
- A running provider resource can still fail runtime compatibility checks.

## Read the code

Read [the recorder and topology](topology.ex), then
[the two tests](../../../test/examples/09_host_providers/09_03_borrowed_and_incompatible/borrowed_and_incompatible_test.exs).
The [shared fixture](../../../test/examples/support/host_provider_case.ex) supplies
real Bedrock, shared Mnesia, and the
[controlled provider](../../../test/support/host_provider.ex).

The [shared scenario functions](../../../test/examples/support/host_provider_scenario.ex)
contain the assertions used by the test runners.

## Run it

```sh
mise exec -- mix test test/examples/09_host_providers/09_03_borrowed_and_incompatible --include example --seed 0
```

Expected result: a borrowed host runs a subscriber and commits an event. Stop
removes its Agent and bindings. Release closes admission and records `retained`;
the same external resource, Core, and guard stay alive. The second test uses an
owned worker with a different namespace. Admission remains closed, no Agent
starts, and explicit release removes the owned resource from provider inventory.

## Important behavior

The borrowed test records provider calls after external setup and checks that
Cluster issues no acquire or release effect. The fixture removes its resource
only after the retention assertions. Incompatible acquisition remains uncertain
until explicit cleanup settles it as `released_before_ready`.

## Optional Docker run

Build the [prepared worker](../../../test/fixtures/docker_host/README.md) and set
`JIDO_CLUSTER_DOCKER_SOCKET` and `JIDO_CLUSTER_DOCKER_IMAGE` as described there.
Then select the explicit runner:

```sh
mise exec -- mix test test/examples/09_host_providers/09_03_borrowed_and_incompatible/docker_acceptance.exs --only example --seed 0
```

The [Docker runner](../../../test/examples/09_host_providers/09_03_borrowed_and_incompatible/docker_acceptance.exs)
uses the same [scenario assertions](../../../test/examples/support/host_provider_scenario.ex)
and the [Docker fixture](../../../test/examples/support/docker_provider_case.ex).
The fixture creates the borrowed container before the scope starts, using an
external owner step. The scope uses Docker's inspection-only borrowed mode.
The test requires the same container, Core, and guard to remain alive after
scope release. Only the fixture removes it after those assertions. The
incompatible case changes the Core namespace and requires no Agent startup
before exact owned cleanup.

This runner passes on the local Engine with the prepared worker image. Missing
Engine or image prerequisites invalidate the run. Default runs do not create
containers.

## Limits

The default run gives controlled provider evidence with native runtimes and real Bedrock.
It does not prove retention or deletion of an actual container. The incompatible
case tests namespace mismatch; lower-level tests cover other compatibility checks.

Previous: [09_02 Lost acquire reply](../09_02_lost_acquire_reply/README.md) |
Next: [09_04 Release guard](../09_04_release_guard/README.md)
