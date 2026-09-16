# 07 Federation

These examples teach best-effort event delivery on fixed connected hosts. Read
[06 Journal recovery](../06_journal_recovery/README.md) first. Required bindings
are part of initial deployment readiness. Publication receipts confirm local
acceptance and bounded submission; they do not confirm Agent execution.

| Example | Learn |
| --- | --- |
| [07_01 Interested hosts](07_01_interested_hosts/README.md) | Declare subscriptions and separate host interest, deployment identity, and namespace |
| [07_02 Envelope and loops](07_02_envelope_and_loops/README.md) | Preserve the Signal, prevent import loops, and suppress a repeated export within its cache window |
| [07_03 Bounded publication](07_03_bounded_publication/README.md) | Reject a full queue before append and observe failure after local acceptance |

Run `mise exec -- mix test test/examples/07_federation --only example --seed 0`.
Each test starts three isolated local BEAM nodes. No credentials are needed.
The first two use the real connected transport. The third controls the transport
boundary with a [recording fixture](../../test/support/federation/recording_transport.ex).
It does not claim real remote delivery for simulated acknowledgements.

Each example defines its own Recorder, topology, and Cluster instance in one
source file. The Recorders use normal Agent routes and store original event
fields. The [example test fixture](../../test/examples/support/federation_case.ex)
starts the hosts and checks cleanup. It uses the general
[peer fixture](../../test/support/cluster_case.ex), which also checks peer exit.
All tests use only `:example`.

The journal and event logs use explicit memory mode. These examples do not prove
durable delivery, machine failure, channel movement, or automatic reconnection.
Agent state and mailboxes remain application concerns outside federation queue
limits. See the [placement guide](../../guides/federated-signals.md)
for the public API and current limits.
