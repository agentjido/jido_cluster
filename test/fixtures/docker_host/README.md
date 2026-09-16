# Prepared Docker worker fixture

This application starts the same Core, HostRuntime, and recorder code that the
Docker backend tests will use. Native peer tests currently verify startup,
provider-step registration, shared checkpoint restore, and process cleanup.
The Linux image builds, and the explicit Docker backend and example tests pass
on the local Engine. The fixture itself is test infrastructure.

Read [runtime.ex](lib/runtime.ex), [recorder.ex](lib/recorder.ex),
[the federation topology](lib/topology.ex), and
[the peer tests](../../jido_cluster/distributed/docker_runtime_test.exs).
The fixture is test infrastructure. It adds no SDK bootstrap API or domain hooks.

## Prepare and build

From the Cluster package, stage the current four V3 package sources:

```sh
python3 test/fixtures/docker_host/prepare.py --output /tmp/jido-docker-build
docker build --tag jido-cluster-test-worker:local /tmp/jido-docker-build
```

The output directory must not exist. The script copies only source, configuration,
Mix files, and this fixture. It also copies an explicit list of the five provider
example definitions, both cumulative example definitions, and the worker-side
location visibility barrier into the fixture application. It does not compile
ExUnit runners or the full test-support tree. It does not copy Git metadata or dependency/build
caches. The generated Docker ignore file also excludes native caches if the
staged application is compiled before the Docker build. The build pins Elixir
1.19.5 and OTP 28.3.1 on Debian Bookworm by image digest. It uses the staged local
packages and compiles a release inside Linux. It does not change sibling sources.

The image contains development build tools because it is an acceptance fixture.
Do not use it as a production image template. Image preparation is outside the
provider: `HostProvider.Docker` starts an existing prepared image and never builds
or pulls one.

## Runtime contract

The Docker provider supplies `JIDO_CLUSTER_HOST_STEP` and
`JIDO_CLUSTER_HOST_NODE`. The test supplies `JIDO_CLUSTER_CONTROL_NODE` and
`JIDO_CLUSTER_COOKIE` at container creation. The cookie is not baked into the
image or saved in provider records. Use a unique node and the isolated peer
cookie. The release uses long node names and disables automatic EPMD startup.
The worker supervisor retains only its eight bootstrap fields; it does not retain
the cookie or the rest of the process environment in its startup arguments.

The proposed first test network is host networking with loopback BEAM names and
the existing host EPMD. Real Docker tests must verify two-way connectivity before
claiming this setup works. No shared network setting is changed by this fixture.

The runtime connects to the control node before it starts Core. With
`JIDO_CLUSTER_TABLE`, it joins the application's Mnesia cluster and requires the
existing table. It does not create storage. Without that variable, persistence
is disabled. Native tests keep the table on the control node, so a worker runtime
restart can restore committed state.

A borrowed worker can omit the provider step and supply `JIDO_CLUSTER_NAMESPACE`.
An explicit namespace can also override the step namespace for an incompatible
runtime test; the Cluster service must then refuse admission. Invalid step data
or a node-name mismatch stops bootstrap before Core starts. Only the two bounded
control-node and table names from trusted runtime configuration become atoms.
No journal record creates atoms.

`JIDO_CLUSTER_CORE` can select the full Elixir name of the fixture Core or one
of the seven example Core names listed in [runtime.ex](lib/runtime.ex). The
runtime matches a fixed atom list. An unknown Core name stops bootstrap.
`JIDO_CLUSTER_ALLOCATION` and `JIDO_CLUSTER_CAPACITY` must be supplied together.
The allocation name must be valid UTF-8 with 1–128 bytes. Capacity must be a
canonical decimal integer from 1 to 256. These limits belong to this test
fixture. If both variables are absent, the existing implicit default allocation
remains in use. Native tests inspect the selected Core and exact allocation.

## Independent worker control

[DockerExec](../../support/docker_exec.ex) uses the Engine exec API and the
release's hidden `rpc` command. It checks the Engine and exact running resource
before it creates the command. It parses Docker's non-TTY stream frames and
requires a matching exec ID, container ID, stopped process, and zero exit code
before it accepts a result. It does not return stderr or raw Engine errors.

[RPC](lib/rpc.ex) carries trusted test calls as bounded ETF terms in Base64.
These values can contain PIDs and references. They are not journal data or a new
SDK endpoint. Requests are limited to 32 KiB, results to 128 KiB, and execution
to 40 seconds. Compressed ETF and trailing bytes are rejected. A timed-out call
kills its task and waits for task termination. The exec command has a separate
OS timeout. All commands use an argv array with no shell interpolation.

The [protocol tests](../../jido_cluster/docker_exec_test.exs) use a local HTTP
fixture. The [RPC tests](../../jido_cluster/docker_rpc_test.exs) check the actual
waiting-process exit on timeout. These tests do not prove Docker operation.
The explicit Docker runner includes a partition case that closes the normal
BEAM connection, inspects the worker through exec, checks that no visible node
connection was added, restores the connection, and deletes the container.

## Local verification

```sh
mise exec -- mix test test/jido_cluster/distributed/docker_runtime_test.exs --include peer --seed 0
```

The tests inspect the public host probe and Agent snapshot, stop the full runtime,
and check that Core, HostRuntime, and Agent processes have stopped. A successful
native test does not prove Linux release startup or container deletion.


## Explicit Docker acceptance

After the prepared image build succeeds and the local Engine responds, run:

```sh
JIDO_CLUSTER_DOCKER_SOCKET=/Users/mhostetler/.orbstack/run/docker.sock \
JIDO_CLUSTER_DOCKER_IMAGE=jido-cluster-test-worker:local \
mise exec -- mix test.docker
```

Set the socket to the explicit local Engine used for the test. The command does
not start or restart Docker and does not build or pull an image. Its preflight
requires both variables, checks Engine identity, and resolves the local image to
an immutable image ID. Missing or unavailable prerequisites invalidate the tests
and return a nonzero exit. They are not passing provider evidence.

The [acceptance cases](../../jido_cluster/distributed/docker_acceptance.exs) use
only `:peer`. The explicit file is outside the normal `*_test.exs` pattern, so
`mix test.all` does not run it. The [Docker fixture](../../support/docker_engine.ex)
registers cleanup before acquisition, uses a unique namespace, inspects exact
step identity, removes only matching immutable IDs, and checks empty discovery.
A failed assertion remains a failure even when fixture cleanup succeeds.

The cases are prepared to check Linux worker connectivity in both directions,
provider-step registration, committed Agent state restore, duplicate acquisition,
bounded discovery, borrowed inspection without effects, stale release refusal,
incompatible runtime observation, failed bootstrap inspection, and actual deletion.
A recovery case withholds the real acquire result, kills the scope owner, restarts
Bedrock, adopts the same resource, commits a federated event, and releases it.
Its [reply-loss fixture](../../support/docker_reply_loss.ex) records the original
step before the effect and retains no Docker options or cookie in its server state.
The five backend cases, seven numbered provider cases, and two cumulative cases
pass against the local Engine with the prepared image.

## Provider example runners

With the same Engine and image variables, `mise exec -- mix test.examples.docker`
selects all five provider examples and the two cumulative Core modes: nine
cases. These explicit runners have only `:example`. Default example runs do not select them. They use
shared scenario functions, a real Bedrock journal, a native control node, and
Docker workers with the example Core name and a dedicated allocation.
The [Docker example fixture](../../examples/support/docker_provider_case.ex)
registers resource cleanup before acquisition. Its
[adapter wrapper](../../support/docker_example_provider.ex) records steps before
effects and can withhold an actual acquisition result or one inspection. It
retains no Docker options or cookie in its server state. Actual inventory comes
from Docker discovery, not that record. All nine cases pass against the local
Docker Engine. The cumulative cases reuse the same system scenario and check three
containers, two owned releases, retained borrowed capacity, and final exact
fixture cleanup. Borrowed resources are prepared under external fixture steps,
then passed to the scope through inspection-only options. Replacement removes
an exact old resource and creates a new one outside the scope request path.
Inventory covers the default and external fixture scopes. Cleanup checks each
recorded step and immutable ID, then empty discovery and node disconnection.
Unknown presence cannot establish process cleanup.
