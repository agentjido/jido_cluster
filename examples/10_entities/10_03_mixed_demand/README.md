# 10_03 Mixed demand

A declared Topology and a new entity compete for the same worker slot.

## What you will learn

- [The declared occupant and entity workload](example.ex) use one Cluster scope.
- An entity cannot activate while the declared claim holds the only slot.

## Read the code

Read [the source](example.ex), [the device Agent](../support/device.ex), and
[the test](../../../test/examples/10_entities/10_03_mixed_demand/mixed_demand_test.exs).
The [peer fixture](../../../test/examples/support/entity_case.ex) configures one
usable slot across two worker peers.

## Run it

```sh
mise exec -- mix test test/examples/10_entities/10_03_mixed_demand --include example --seed 0
```

Expected result: entity admission fails with `:no_capacity` while the declared
Agent runs. A confirmed stop releases its claim, then the entity commits one
event under its own claim.

## Important behavior

The failed entity request does not leave a running Agent. Cleanup stops the
scope and checks the worker Agent pools.

## Limits

Capacity is a configured connected-scope slot budget. This case does not
grant admission across disconnected control islands.

Previous: [10_02 Entity move](../10_02_entity_move/README.md) |
Next: [system examples](../../11_system/README.md)
