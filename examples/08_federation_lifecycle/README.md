# 08 Federation lifecycle

These examples extend [07 Federation](../07_federation/README.md) with declared
bindings that follow accepted placement. Event delivery remains best effort.

| Example | Learn |
| --- | --- |
| [08_01 Subscription move](08_01_subscription_move/README.md) | Retain a subscriber's Ref, logical binding ID, and committed events through a drain |
| [08_02 Bridge restart](08_02_bridge_restart/README.md) | Repair declared bindings after bridge loss while the current Agent and claims stay unchanged |
| [08_03 Shared cleanup](08_03_shared_cleanup/README.md) | Stop one deployment and retain the other’s bindings and native transport |
| [08_04 Uncertain attachment](08_04_uncertain_attachment/README.md) | Keep target readiness separate from binding completion after a lost journal reply |

Run `mise exec -- mix test test/examples/08_federation_lifecycle --only example --seed 0`.
The test starts three isolated BEAM nodes with a real Bedrock journal and shared
Mnesia Agent storage. No credentials or external service are needed.

The [lifecycle fixture](../../test/examples/support/federation_lifecycle_case.ex)
checks resource cleanup. Tests use only `:example`. All four examples and the
later cumulative system cases pass locally. Read the
[S5 acceptance record](../../docs/design/05_federation-lifecycle/plan.md) for
the failure audit and proof limits.
