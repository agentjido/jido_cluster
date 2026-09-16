# Example tests

Tests mirror the [numbered examples](../../examples/README.md). Agent and Topology definitions live in that source catalog. These test cases are the run path for each example and check its stated result through public APIs.

```sh
mise exec -- mix test.examples
mise exec -- mix test.all
```

All example tests use only `:example`, including tests that start nodes. The normal unit run excludes them. Example-only fixtures live in `test/examples/support/`: the [deployment fixture](support/deployment_case.ex) and [shared-capacity fixture](support/shared_capacity_case.ex). General node setup is in [ClusterCase](../support/cluster_case.ex). Follow the [test instructions](../AGENTS.md) and [example instructions](../../examples/AGENTS.md).

[06 Journal recovery](../../examples/06_journal_recovery/README.md) uses real Bedrock
and Mnesia for interrupted drains, lost replies, live-source uncertainty, and
adapter choice. Its peer tests use only the `:example` tag.

[07 Federation](../../examples/07_federation/README.md) covers declared interest,
scope isolation, loop prevention, duplicate exports, and bounded publication.
The [federation fixture](support/federation_case.ex) starts isolated static hosts
and checks deployment, instance, and Core cleanup. Its tests use only `:example`.

[08 Federation lifecycle](../../examples/08_federation_lifecycle/README.md) proves
subscriber movement, explicit bridge repair, shared transport cleanup, and
uncertain attachment recovery with a real Bedrock journal and shared Mnesia Agent storage.
The [lifecycle fixture](support/federation_lifecycle_case.ex) checks old and current
channel component cleanup, Agent exit, released claims, Core exit, and journal exit.

[09 Host providers](../../examples/09_host_providers/README.md) covers acquisition
admission, release after cleanup, lost-reply recovery, stale resource exclusion,
and abrupt owner loss with real Bedrock.
The [provider fixture](support/host_provider_case.ex) uses a controlled provider
and checks native process cleanup. These cases do not establish Docker acceptance.

[10 Entities](../../examples/10_entities/README.md) covers concurrent first
activation, cooperative movement, and shared capacity. The [entity fixture](support/entity_case.ex) starts two worker peers with
shared Mnesia Agent storage. The unit contracts check pending activation,
journal recovery and the eight-identity bound.

[11 System](../../examples/11_system/README.md) combines partial drain recovery,
delayed target visibility, independent progress during source uncertainty, and
checked cleanup in managed and attached Core modes. Its
[system fixture](support/system_lifecycle_case.ex) uses real Bedrock and Mnesia.

The [shared system scenario](support/system_lifecycle_scenario.ex) also runs for
[11_02 Provider lifecycle](../../examples/11_system/11_02_provider_lifecycle/README.md).
Its controlled provider checks exact host identity through recovery, owned release,
and borrowed retention. The explicit
[Docker cumulative runner](11_system/11_02_provider_lifecycle/docker_acceptance.exs)
selects managed and attached Core modes, with the same scenario and real Bedrock.
Both cases pass on the local Engine with the prepared worker image.

All five provider examples have explicit `docker_acceptance.exs` runners,
selected by `mise exec -- mix test.examples.docker` after Engine/image preflight.
They use only `:example` and stay outside the default test selection. They call
the same [scenario functions](support/host_provider_scenario.ex) as the native
examples. The [Docker fixture](support/docker_provider_case.ex) requires actual
resource observations and uses independent worker control. These runners are
prepared and pass on the local Engine. Exact resource cleanup is part of each
case.
