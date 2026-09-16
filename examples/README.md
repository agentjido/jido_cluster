# Jido Cluster examples

Catalog and authoring conventions follow core Jido, adapted to Cluster. See the
[example instructions](AGENTS.md) for source layout, README content, public API
usage, and deterministic tests.

These examples are living documentation. Definitions live here. Runnable test cases live under `test/examples/` and check each stated result. The folder numbers set the reading order. Groups 01–03 were retired;
the current path starts at 04. Existing group numbers remain stable.

| Group | Example | Learn |
| --- | --- | --- |
| [06 Journal recovery](06_journal_recovery/README.md) | [06_01 Interrupted drain](06_journal_recovery/06_01_interrupted_drain/README.md) | Recover the original movement request after coordinator loss |
| 06 Journal recovery | [06_02 Unknown write](06_journal_recovery/06_02_unknown_write/README.md) | Resolve a committed journal write whose reply was lost |
| 06 Journal recovery | [06_03 Uncertain source](06_journal_recovery/06_03_uncertain_source/README.md) | Keep both claims while a live source is disconnected |
| 06 Journal recovery | [06_04 Adapter choice](06_journal_recovery/06_04_adapter_choice/README.md) | Select journal storage and retain stopped intent |
| [07 Federation](07_federation/README.md) | [07_01 Interested hosts](07_federation/07_01_interested_hosts/README.md) | Deliver only to the declared deployment and namespace |
| 07 Federation | [07_02 Envelope and loops](07_federation/07_02_envelope_and_loops/README.md) | Preserve Signals without import loops and suppress repeated exports |
| 07 Federation | [07_03 Bounded publication](07_federation/07_03_bounded_publication/README.md) | Reject full queues before append and report later failure |
| [08 Federation lifecycle](08_federation_lifecycle/README.md) | [08_01 Subscription move](08_federation_lifecycle/08_01_subscription_move/README.md) | Retain Ref identity, binding identity, and committed events through a drain |
| 08 Federation lifecycle | [08_02 Bridge restart](08_federation_lifecycle/08_02_bridge_restart/README.md) | Repair bindings and connections while the accepted Agent stays alive |
| 08 Federation lifecycle | [08_03 Shared cleanup](08_federation_lifecycle/08_03_shared_cleanup/README.md) | Retain another deployment’s bindings and native transport after stop |
| 08 Federation lifecycle | [08_04 Uncertain attachment](08_federation_lifecycle/08_04_uncertain_attachment/README.md) | Recover unknown target attachment intent without premature completion |
| [09 Host providers](09_host_providers/README.md) | [09_01 Acquired topology](09_host_providers/09_01_acquired_topology/README.md) | Admit provider capacity and release it after Agent and binding cleanup |
| 09 Host providers | [09_02 Lost acquire reply](09_host_providers/09_02_lost_acquire_reply/README.md) | Adopt the original resource after owner and Bedrock restart |
| 09 Host providers | [09_03 Borrowed and incompatible hosts](09_host_providers/09_03_borrowed_and_incompatible/README.md) | Retain borrowed infrastructure and reject an incompatible runtime |
| 09 Host providers | [09_04 Release guard](09_host_providers/09_04_release_guard/README.md) | Wait for confirmed binding cleanup and reject stale resource handles |
| 09 Host providers | [09_05 Abrupt death cleanup](09_host_providers/09_05_abrupt_death_cleanup/README.md) | Resume saved deletion while preserving other resource identities |
| [10 Entities](10_entities/README.md) | [10_01 First activation](10_entities/10_01_first_activation/README.md) | Admit one device for concurrent first calls from independent peers |
| 10 Entities | [10_02 Entity move](10_entities/10_02_entity_move/README.md) | Keep Ref, state, and revision across a cooperative drain |
| 10 Entities | [10_03 Mixed demand](10_entities/10_03_mixed_demand/README.md) | Share one capacity budget with declared Topology demand |
| [11 System](11_system/README.md) | [11_01 Deployment lifecycle](11_system/11_01_deployment_lifecycle/README.md) | Recover a partial drain and retain independent progress during source uncertainty |
| 11 System | [11_02 Provider lifecycle](11_system/11_02_provider_lifecycle/README.md) | Retain acquired host identity through recovery and preserve borrowed capacity at cleanup |

New instance examples: [04 Deployment](04_deployment/README.md) covers managed
core, attached core, and request identity. [05 Shared capacity](05_shared_capacity/README.md) covers competing admission,
shared cleanup, drain, transition capacity, and progress during uncertainty.
[06 Journal recovery](06_journal_recovery/README.md) covers interrupted drains,
lost write replies, uncertain sources, and explicit adapter choice with real Bedrock.

Example source code compiles in `dev` and `test`. It does not compile in `prod`. Tests mirror each numbered folder under `test/examples/` and use only the `:example` tag. The normal test command excludes this tag.

Run from `jido_cluster`:

```sh
mise exec -- mix test.examples
```

Use `mix test.peer` for node tests and `mix test.all` for all active tests. See [testing](../guides/testing.md), [example instructions](AGENTS.md), and [example tests](../test/examples/README.md). Keep source, tests, and README claims in the same change.

## Reading and test method

Read each numbered README, its main topology or Agent definition, and then its
matching test. Each example states one main contract and its failure or cleanup
boundary. Fixtures remain beside their consumer; shared helpers use the smallest
common scope. Stable examples use implemented public APIs. Incomplete behavior
belongs in research and must be identified as such.

Run one example directly through ExUnit:

```sh
mise exec -- mix test test/examples/05_shared_capacity/05_03_shared_drain --include example --seed 0
```

Cluster uses test cases as executable documentation. There are no separate demo
runners. Default examples need no hosted credentials. External integration tests
must state their prerequisites and must not treat a missing backend as success.

Future example groups are specified in the [slice plans](../docs/design/README.md)
and [example test method](../docs/design/00_architecture/example-testing.md).
Those plans do not add runnable entries to this catalog until implemented.
