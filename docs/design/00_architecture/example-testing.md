# Example-based test method

Status: acceptance-test design for S1–S7. These scenarios are planned, not current
coverage. Each slice plan contains its setup, scenario table, and proof limits.

## Build each slice from observable behavior

1. Write the example's short contract: what the developer does and what must hold.
2. Define the public observation needed to prove it. If missing, design that
   status or lifecycle contract before relying on private process state.
3. Write the failing unit contracts and the example test using the proposed API.
4. Implement the smallest runtime path, then add peer fault cases around its
   ownership and acknowledgement boundaries.
5. Publish source and README with the passing test. Keep unfinished material in
   research until its promised behavior exists.

The example is an acceptance contract, not a script or benchmark. Keep fast edge
cases in unit tests and exhaustive fault permutations in peer/adapter tests. Do
not duplicate the full fault matrix in every example.

## Layout and tagging

Use matching numbered folders under `examples/` and `test/examples/`. Definitions
live in the former; ExUnit cases live in the latter. No `demo.exs` runners.
Use `JidoCluster.Test.ClusterCase, tag: :example` for peer examples and only the
`:example` tag. Normal unit runs exclude examples. Keep general helpers in
`test/support/` and example-only helpers in `test/examples/support/`.

Keep current example groups 01–03 as regression evidence. Proposed groups 04–10
map to S1–S7. Each README states setup, command, proof, failure behavior, and limits.
Comments should explain test phases and why readiness or retirement barriers exist.

## Deterministic setup and failure control

Use isolated peers, unique namespaces/scope keys, bounded waits, and independent
peer channels for competing requests. Register cleanup before setup can fail.
Use monitors, public state, and controlled test adapters to establish ordering.
Do not use fixed sleeps as proof of readiness, absence, or completed cleanup.

Keep fault controls in test support. Use explicit adapter hooks or fixtures for
before-write, after-write/before-response, before-activation, and after-retirement
boundaries. Do not expose test control fields in product Signals or example Actions.
Label process crash, node disconnect, confirmed node death, and backend loss as
different cases. A disconnect does not prove that the remote writer stopped.

For negative event assertions, record a bounded completed batch and its routing
outcomes. An empty mailbox at one instant is not proof of no forwarding. For
capacity assertions, combine public claims with observed Agent starts and exits.

## Cleanup is part of the result

Monitor owned processes to termination. Retain borrowed core instances and hosts.
Check that shared resources remain for other deployments. Verify deletion against
real providers when that is the claim. Cleanup failures fail the test and retain
enough scoped resource identity to diagnose them. Test cleanup must never delete
unrelated application or provider resources.

## Run and promote

From `jido_cluster`, use the pinned tools:

```sh
mise exec -- mix test --include example test/examples/<group>/<scenario>/<case>_test.exs --seed 0
mise exec -- mix test.examples
mise exec -- mix test.peer
mise exec -- mix test.all
```

The first command is a path template, replaced with the actual new test path.
Record the seed for races; use controlled barriers to exercise meaningful orderings
rather than relying on repeated lucky runs. Run required format, compile, and
quality checks for implementation changes.

Base examples require no hosted credentials. S3 requires a real local Bedrock
integration; S6 requires a real Docker proof in addition to fake-provider tests.
Dedicated integration runners/jobs must make those prerequisites explicit and
must not report an unavailable backend as a pass. They still run tagged ExUnit
cases, not separate demo scripts. Run optional-dependency absence checks in a
separate consumer/build setup that actually omits those dependencies.

Each plan records scenario links, commands, seeds, backend, results, and cleanup.
An example passing does not establish untested partition, delivery, or durability
guarantees. Preserve those limits in the README and public documentation.

## Cumulative acceptance

In addition to slice examples, build the
[system lifecycle scenario](lifecycle-contracts.md#cumulative-system-example).
Keep it research-only while incomplete. S5 requires its static-host variant and
S6 requires its real-provider variant. Capture actual process exits during crash
recovery; do not use unchanged PIDs as the recovery contract. Verify unrelated
progress while another allocation is uncertain and check final cleanup across
Agents, bindings, claims, and provider resources.

## Model-based complements

Use generated pure-model sequences for claim conservation, idempotent confirmation,
request replay, and cleanup exclusions. These complement the public examples.
Include stale observations, lost replies, host-guard restart, and abrupt death
without termination callbacks. Compare public outcomes with a small independent
model; avoid testing only that internal functions call themselves consistently.
