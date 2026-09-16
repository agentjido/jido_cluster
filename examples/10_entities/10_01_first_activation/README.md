# 10_01 First activation

Two callers can address a new device by domain key. Cluster admits one core
Topology activation and one shared host claim for that identity.

## What you will learn

- The [workload definition](example.ex) gives the domain key a stable versioned
  Topology ID and core Ref.
- Concurrent first calls use the scope service's serial admission path. A
  candidate hash does not start another Agent.

## Read the code

Read [the workload](example.ex), then [the device Agent](../support/device.ex),
and then [the test](../../../test/examples/10_entities/10_01_first_activation/first_activation_test.exs).
The [peer fixture](../../../test/examples/support/entity_case.ex) starts the
shared scope and workers.

## Run it

```sh
mise exec -- mix test test/examples/10_entities/10_01_first_activation --include example --seed 0
```

Expected result: both peer calls return committed Agent state. The device has
count two, one core Ref, one active claim, and one active worker process.

## Important behavior

`Entity.lookup/3` does not activate a missing identity. `Entity.call/5` admits
it, waits for readiness, and submits its Signal once. A timeout reports pending
or uncertainty; Cluster does not replay the Signal.

## Limits

This connected-peer case does not grant a partition-safe writer lease or
application event deduplication. The test uses two different event IDs.

Previous: [09_05 Abrupt death cleanup](../../09_host_providers/09_05_abrupt_death_cleanup/README.md) |
Next: [10_02 Entity move](../10_02_entity_move/README.md)
