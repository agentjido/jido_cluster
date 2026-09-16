# 09_04 Release guard

Keep a host while required cleanup is unconfirmed, and refuse a stale resource
handle after the provider reports a different incarnation.

## What you will learn

- A network disconnect does not prove remote cleanup or resource death.
- Host release waits for retained Agent and federation claims to settle.
- Matching step labels do not authorize deletion of a replacement resource.

## Read the code

Read [the recorder and topology](topology.ex), then
[the tests](../../../test/examples/09_host_providers/09_04_release_guard/release_guard_test.exs).
The [shared fixture](../../../test/examples/support/host_provider_case.ex) uses
real Bedrock, native peers, and a
[controlled provider](../../../test/support/host_provider.ex).

The [shared scenario functions](../../../test/examples/support/host_provider_scenario.ex)
contain the assertions used by the test runners.

## Run it

```sh
mise exec -- mix test test/examples/09_host_providers/09_04_release_guard --include example --seed 0
```

Expected result: a required subscriber commits an event. A live network partition
then prevents confirmation of its binding cleanup. Stop and host release remain
uncertain, the remote mirror processes remain alive, and no provider delete call
occurs. Reconnect and reconciliation settle the original stop and release requests.
All recorded Agent and channel processes are checked for exit.

The second test replaces the provider's resource observation with a new ID and
incarnation at the same step. A direct stale release is rejected. Scope release
also retains the new resource and its old recorded handle as uncertain.

## Important behavior

The partition blocks both connection directions with test-local cookies. Independent
peer channels inspect the live remote runtime. Cleanup restores reachability even
if an assertion fails. Resource identity tests use actual handles returned by the
controlled provider; the replacement is removed by its external fixture owner only
after preservation assertions.

## Optional Docker run

Build the [prepared worker](../../../test/fixtures/docker_host/README.md) and set
`JIDO_CLUSTER_DOCKER_SOCKET` and `JIDO_CLUSTER_DOCKER_IMAGE` as described there.
Then select the explicit runner:

```sh
mise exec -- mix test test/examples/09_host_providers/09_04_release_guard/docker_acceptance.exs --only example --seed 0
```

The [Docker runner](../../../test/examples/09_host_providers/09_04_release_guard/docker_acceptance.exs)
uses the same [scenario assertions](../../../test/examples/support/host_provider_scenario.ex)
and the [Docker fixture](../../../test/examples/support/docker_provider_case.ex).
The partition case inspects the worker through independent Engine exec while
its visible BEAM link is closed. After deletion, exact container absence and
node disconnection establish worker-process cleanup; an unavailable query
cannot pass that check. Connection cleanup does not contact a deleted worker.

The replacement case removes the old container and creates a new ID and
incarnation outside the scope's request path. Docker accepts an idempotent
release of the already-absent old ID. The test confirms that old ID's absence
and requires the replacement to remain running. The default controlled
provider still rejects the stale handle. Both cases require the scope to keep
its original recorded identity and refuse to release the replacement.

This runner passes on the local Engine with the prepared worker image. Missing
Engine or image prerequisites invalidate the run. Default runs do not create
containers.

## Limits

In the default run, provider inventory is controlled. Replacing an observation does not replace a
native VM, and empty inventory does not prove container deletion. Shared Mnesia can
report the deliberate partition; this test makes no partition-write guarantee.
The explicit Docker runner supplies the container evidence.

Previous: [09_03 Borrowed and incompatible hosts](../09_03_borrowed_and_incompatible/README.md) |
Next: [09_05 Abrupt death cleanup](../09_05_abrupt_death_cleanup/README.md)
