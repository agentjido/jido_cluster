# Host providers

Read these examples after [federation lifecycle](../08_federation_lifecycle/README.md).
Host acquisition, runtime admission, and deployment readiness have separate results.
A durable journal retains the accepted provider step through owner loss.

1. [09_01 Acquired topology](09_01_acquired_topology/README.md): acquire capacity,
   deliver an event, and release only after Agent and binding cleanup.
2. [09_02 Lost acquire reply](09_02_lost_acquire_reply/README.md): restart the owner
   and Bedrock, then inspect and adopt the original resource.
3. [09_03 Borrowed and incompatible hosts](09_03_borrowed_and_incompatible/README.md):
   retain borrowed infrastructure and refuse an incompatible owned worker.
4. [09_04 Release guard](09_04_release_guard/README.md): retain resources while
   binding cleanup is unconfirmed and reject stale resource handles.
5. [09_05 Abrupt death cleanup](09_05_abrupt_death_cleanup/README.md): resume saved
   cleanup after owner death while other resource identities remain.

The default examples use isolated native BEAM peers, real Bedrock for the scope
journal, shared Mnesia for Agent state, and a controlled provider. They need no
credentials. They do not create containers or establish Docker acceptance.
The real Docker runs also pass; see the
[S6 acceptance record](../../docs/design/06_host-providers/plan.md#real-docker-acceptance-and-s6-audit).

```sh
mise exec -- mix test test/examples/09_host_providers --include example --seed 0
```

The [test fixture](../../test/examples/support/host_provider_case.ex) checks
Agent, channel component, host guard, Core, provider, and journal cleanup.

All five examples have explicit Docker runners. After the worker image and
Engine prerequisites in the [worker instructions](../../test/fixtures/docker_host/README.md)
are ready, run `mise exec -- mix test.examples.docker`. The seven numbered cases reuse the
[scenario functions](../../test/examples/support/host_provider_scenario.ex) from
the default tests. The same command also selects both cumulative Core modes.
All nine cases pass on the local Engine with the prepared image.
