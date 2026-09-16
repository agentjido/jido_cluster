# 07_02 Envelope and loops

Keep event identity through bidirectional transport without re-exporting imports.

## Read the code

Read [the Recorders and topology](events.ex), then the
[test](../../../test/examples/07_federation/07_02_envelope_and_loops/envelope_and_loops_test.exs).
The topology declares one subscriber on the `origin` host and one on the
`destination` host. Runtime creates connections in both directions.

Setup uses the [example fixture](../../../test/examples/support/federation_case.ex)
and [peer fixture](../../../test/support/cluster_case.ex).

## Run

```sh
mise exec -- mix test test/examples/07_federation/07_02_envelope_and_loops --only example --seed 0
```

## Expected result

An explicit publication reaches both Recorders with its original Signal fields.
The receiver's Bridge has no export caused by the import. The test submits the
same export identity again through the connected transport and observes a
`:duplicate` receipt without another Bus record. A fresh reverse publication
reaches both Agents. Completed export batches leave exactly the two expected
Signals in each Bus and no re-export loop.

## Boundaries and cleanup

The public control-node facade starts the forward publication. The test uses
public Mirror/Bridge handles for the reverse host-local publication. It rebuilds
the repeated transport envelope from the original publication receipt and the
public publisher generation. This is a protocol test, not an application retry
policy. Duplicate suppression lasts only within the configured cache window
(default 60 seconds); expiry and generation loss can permit a later duplicate.
Publishing the same Signal through the facade again creates a new export ID.

The test checks Agent and mirror cleanup, released claims, host/Core cleanup,
and peer exit. It does not prove global ordering, durable replay, or exactly-once
delivery. No application test hook or timed absence assertion is used.

Previous: [07_01 Interested hosts](../07_01_interested_hosts/README.md) | Next: [07_03 Bounded publication](../07_03_bounded_publication/README.md)

Return to [07 Federation](../README.md).
