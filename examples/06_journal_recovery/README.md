# 06 Journal recovery

These examples teach explicit recovery of retained placement intent. Core owns
Agent checkpoints and accepted topology targets. Cluster owns the request journal,
claims, and recovery order. Read them after [05 Shared capacity](../05_shared_capacity/README.md).

| Example | Learn |
| --- | --- |
| [06_01 Interrupted drain](06_01_interrupted_drain/README.md) | Resume recorded movement after coordinator loss |
| [06_02 Unknown write reply](06_02_unknown_write/README.md) | Find the original request after a committed write loses its reply |
| [06_03 Uncertain source](06_03_uncertain_source/README.md) | Preserve uncertainty while a live source is disconnected |
| [06_04 Adapter choice](06_04_adapter_choice/README.md) | Keep journal choice separate from Agent persistence and retain stopped intent |

Run `mise exec -- mix test test/examples/06_journal_recovery --only example --seed 0`.
The tests use isolated local peers, actual Bedrock, and Mnesia. They need no hosted
service or credentials. Bedrock is configured for relaxed single-node filesystem
durability, so these tests do not prove machine or replica failure.

The [shared Worker](support/worker.ex) has one command and no test hooks.
The [test fixture](../../test/examples/support/journal_recovery_case.ex) owns backend
and peer setup. Observe current readiness after `Jido.Cluster.reconcile/1`; its
`:ok` only means that recovery was accepted. Review the [placement guide](../../guides/named-deployments.md)
for limits, including the Core persistence requirement after movement.
