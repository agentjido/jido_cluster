# 11_02 Provider lifecycle

Recover shared deployments on acquired capacity, then release owned hosts while
retaining borrowed infrastructure.

## What you will learn

- Combine host ownership with shared claims, journal recovery, and federation.
- Retain provider identity through interrupted movement and owner restart.
- Use independent borrowed capacity while another source is uncertain.
- Release owned hosts only after all deployments and bindings stop.

## Read the code

Read [the Recorder and topologies](subscriber.ex), then the
[test](../../../test/examples/11_system/11_02_provider_lifecycle/provider_lifecycle_test.exs).
The [shared scenario](../../../test/examples/support/system_lifecycle_scenario.ex)
executes the same lifecycle as the static system example. The
[system fixture](../../../test/examples/support/system_lifecycle_case.ex) configures
two owned worker resources and one borrowed worker, with real Bedrock for the scope
journal and shared Mnesia for Agent state. The default backend is the
[controlled provider](../../../test/support/host_provider.ex).
The explicit [Docker runner](../../../test/examples/11_system/11_02_provider_lifecycle/docker_acceptance.exs)
uses the same scenario through the
[Docker system fixture](../../../test/examples/support/docker_system_lifecycle_case.ex).

The scenario uses the [journal barrier](../../../test/examples/support/journal_reply_loss.ex),
[location barrier](../../../test/examples/support/location_visibility_barrier.ex),
[movement barrier](../../../test/support/movement_barrier.ex),
[owner crash fixture](../../../test/examples/support/journal_recovery_case.ex), and
[federation fixture](../../../test/examples/support/federation_lifecycle_case.ex).

## Run it

```sh
mise exec -- mix test test/examples/11_system/11_02_provider_lifecycle --only example --seed 0
```

With a prepared worker image and a responding Docker Engine, run the two real
provider cases through `mise exec -- mix test.examples.docker`. Set the Engine
socket and image variables as shown in the
[worker fixture instructions](../../../test/fixtures/docker_host/README.md#explicit-docker-acceptance).
These cases are outside the default test selection.

Expected result: acquisition opens admission for the three configured hosts.
Two subscribers retain their Refs and committed events through a partial drain
and owner restart. A later source partition retains uncertain claims, while the
independent borrowed allocation accepts work. Reconnect restores binding readiness
and fresh delivery. Previously stopped intent remains stopped.

The exact provider inventory remains unchanged at recovery and partition
checkpoints. No second acquisition occurs after owner restart. After every
subscriber stops, release removes only the two owned resources. Bedrock records
them as released and borrowed capacity as retained. Its resource and guard remain
until the external fixture owner performs final cleanup.

## Important behavior

Managed and attached control Core modes run the same assertions. The test checks
actual Agent exits during recovery, pending Ref visibility, retained claim counts,
old and current channel process cleanup, and exact provider release targets.
The independent borrowed resource is not created or deleted by scope operations.

## Limits

The default run uses native peers and provider records, so it does not prove
Docker container lifetime or networking. Both Docker Core modes pass on the
local Engine with three real containers. Bedrock uses a
single control peer with relaxed durability. Mnesia can report the deliberate
partition; the test does not write isolated subscribers during that interval.
Publication is best effort and has no durable replay.

Previous: [11_01 Deployment lifecycle](../11_01_deployment_lifecycle/README.md).
Also read [the host provider examples](../../09_host_providers/README.md).
