# 07_03 Bounded publication

Reject publication before local append when all outbound slots are occupied.

## Read the code

Read [the Recorder, topology, and two-slot configuration](events.ex), then the
[test](../../../test/examples/07_federation/07_03_bounded_publication/bounded_publication_test.exs).
The [recording transport fixture](../../../test/support/federation/recording_transport.ex)
holds export completion and returns a controlled failure. It replaces only the
Bridge transport targets in the test. Application source has no failure hooks.

Setup uses the [example fixture](../../../test/examples/support/federation_case.ex)
and [peer fixture](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/07_federation/07_03_bounded_publication --only example --seed 0
```

## Expected result

Two publication receipts return after local append while their exports remain
held. Public federation status reports two occupied slots and two in-flight
publications. A third call returns `{:error, :capacity}` and adds no local Bus
record or export. Releasing the fixture drains the accepted work and returns
the slots. A later simulated connection failure follows another successful local
receipt. Export status then reports one rejection and degraded health; all three
accepted Signals remain in the local Bus log.

## Boundaries and cleanup

The fake acknowledgements establish the local admission and reporting contract.
They do not prove delivery to B; the preceding examples use the real transport
for that proof. Live connection health and historical export outcomes are separate
observations. The completed deployment operation remains unchanged.

The test stops deployment resources, its recording fixture, host guards, Cores,
and peers, and checks that claims are released. Queue limits do not bound Agent
mailboxes, caller memory, or ordinary local Bus publishers. A publication timeout
can be uncertain and does not authorize automatic business replay.

Previous: [07_02 Envelope and loops](../07_02_envelope_and_loops/README.md)

Return to [07 Federation](../README.md).
