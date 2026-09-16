# Entity capabilities

Read these examples after [shared capacity](../05_shared_capacity/README.md) and
[journal recovery](../06_journal_recovery/README.md). Each device identity is one
bounded core Topology in a shared Cluster scope.

1. [10_01 First activation](10_01_first_activation/README.md): two peers call one
   new identity, but the scope admits one Agent and one claim.
2. [10_02 Entity move](10_02_entity_move/README.md): a host drain keeps the
   device Ref, committed state, and revision.
3. [10_03 Mixed demand](10_03_mixed_demand/README.md): declared Topology demand
   and entity demand use the same slot budget.

The [device Agent](support/device.ex) and [scope definition](support/scope.ex)
are shared by these examples. The [test fixture](../../test/examples/support/entity_case.ex)
starts isolated peers and shared Mnesia Agent storage. The tests need no
credentials or external service.

```sh
mise exec -- mix test test/examples/10_entities --include example --seed 0
```

Entity activation has an eight-identity bound per scope. The journal has a
shared 16-deployment bound. The [benchmark](../../bench/entity_activation.exs)
measures eight local durable activations and journal size; it is not a throughput
or partition-safety claim.
