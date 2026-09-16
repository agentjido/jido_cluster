# 09_05 Abrupt death cleanup

Resume a saved host deletion after abrupt owner loss, while preserving live,
borrowed, and replacement resource identities.

## What you will learn

- A confirmed journal receipt precedes the provider delete effect.
- Recovery inspects saved intent after owner and Bedrock restart.
- One resource's cleanup does not authorize deletion of other resources.

## Read the code

Read [the recorder and topology](topology.ex), then
[the test](../../../test/examples/09_host_providers/09_05_abrupt_death_cleanup/abrupt_death_cleanup_test.exs).
The [shared fixture](../../../test/examples/support/host_provider_case.ex) starts
four worker peers and a control peer. A
[journal fault fixture](../../../test/examples/support/journal_reply_loss.ex)
loses a selected write reply after real Bedrock commits it. The
[controlled provider](../../../test/support/host_provider.ex) retains resource
identities independently of the scope owner.

The [shared scenario functions](../../../test/examples/support/host_provider_scenario.ex)
contain the assertions used by the test runners.

## Run it

```sh
mise exec -- mix test test/examples/09_host_providers/09_05_abrupt_death_cleanup --include example --seed 0
```

Expected result: the target subscriber commits an event and stops. Its deletion
receipt is stored, but the reply is lost, so no provider delete call occurs.
The test kills the owner without termination callbacks and restarts Bedrock.
Reconciliation deletes only the exact target resource.

An independent live resource remains. Its Agent restarts at the same Ref, restores
committed state, and receives a fresh event. A borrowed resource and its guard remain.
A replacement candidate with a new incarnation remains uncertain and is not deleted.
The stopped target deployment stays stopped.

## Important behavior

The test checks exact inventory before and after recovery, the provider delete
call log, old Agent and channel process exit, new Agent state, and saved host
intent. Independent work stops at the end. The external fixture owner then removes
the borrowed and replacement controls, and all runtime processes are checked.

## Optional Docker run

Build the [prepared worker](../../../test/fixtures/docker_host/README.md) and set
`JIDO_CLUSTER_DOCKER_SOCKET` and `JIDO_CLUSTER_DOCKER_IMAGE` as described there.
Then select the explicit runner:

```sh
mise exec -- mix test test/examples/09_host_providers/09_05_abrupt_death_cleanup/docker_acceptance.exs --only example --seed 0
```

The [Docker runner](../../../test/examples/09_host_providers/09_05_abrupt_death_cleanup/docker_acceptance.exs)
uses the same [scenario assertions](../../../test/examples/support/host_provider_scenario.ex)
and the [Docker fixture](../../../test/examples/support/docker_provider_case.ex).
The fixture uses four actual worker containers: the cleanup target, a live
owned worker, a borrowed worker, and an owned worker that the fixture replaces.
The same scenario holds a real Bedrock deletion receipt, kills the owner,
restarts Bedrock, and requires only the target container to disappear. The
other three resource identities must remain. Live work must restore committed
state before final fixture cleanup removes the remaining exact containers.

This runner passes on the local Engine with the prepared worker image. Missing
Engine or image prerequisites invalidate the run. Default runs do not create
containers.

## Limits

The default run uses real Bedrock and shared Mnesia. Its provider resources
are controlled records, not containers. The replacement changes a provider
observation without replacing a native VM. This proves Cluster's selection of
cleanup targets. The explicit Docker runner checks actual preservation and deletion.

Previous: [09_04 Release guard](../09_04_release_guard/README.md)
