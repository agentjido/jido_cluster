# 10_02 Entity move

A device keeps its core Ref and committed state when Cluster drains its host.

## What you will learn

- [The workload](example.ex) maps one domain identity to the same Topology ID
  before and after movement.
- The shared drain path retires the source claim after the target is ready.

## Read the code

Read [the workload](example.ex), [the device Agent](../support/device.ex), and
[the test](../../../test/examples/10_entities/10_02_entity_move/entity_move_test.exs).
The [peer fixture](../../../test/examples/support/entity_case.ex) supplies
shared Mnesia checkpoints on both workers.

## Run it

```sh
mise exec -- mix test test/examples/10_entities/10_02_entity_move --include example --seed 0
```

Expected result: the source Agent exits, the target has the same Ref and state
at revision one, and a new event commits revision two at the target.

## Important behavior

The test reads accepted location through `Entity.lookup/3` and host claims
through `Cluster.claims/1`. It pauses a drain after target readiness and checks
that both transition claims remain charged; another request for the same key
uses the existing activation. It does not route to the candidate selected by a
hash. Cleanup stops the scope and confirms no worker Agents remain.

## Limits

This cooperative connected-host move does not prove replacement of an
unreachable writer. Cluster reports that case as uncertain.

Previous: [10_01 First activation](../10_01_first_activation/README.md) |
Next: [10_03 Mixed demand](../10_03_mixed_demand/README.md)
