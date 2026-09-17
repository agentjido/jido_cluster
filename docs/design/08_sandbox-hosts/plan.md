# S8 — Sandbox host plan

Status: proposed design, source review, and disposable live network probe,
2026-09-16. The probe resources were removed. No Fly or Sprite adapter exists.

## Outcome and scope

Show one trusted `Jido.AI.Agent` running on BEAM nodes inside Fly Machines and
Sprites. Use the `eboss` Fly organization for the first live proof. Run the
Phoenix and Cluster control node on Fly, then control it from a laptop browser.
Use a dedicated Fly worker app and one Sprite as two host types. The Agent calls
a model and a read-only tool, commits a conversation result, drains after the
request ends, then answers a second question on the other host from the same
Agent Ref and prior conversation. Show the host of each answer and its tool
receipt in the UI. A two-Fly-worker run can precede the mixed-host run.

Use the phrase **Agents on BEAM nodes inside sandboxes**. A BEAM process is not
an untrusted-code security boundary. The first demo runs trusted application
code in prepared releases, not arbitrary code supplied by viewers. Its model
credentials are available to that worker process and its trusted code. They
are not isolated from code run in that worker or trusted connected BEAM peers.
The Erlang cookie also grants broad access to connected nodes. Do not run
untrusted code in the same Sprite that holds the worker cookie or model key.

## Current facts

- `Jido.Cluster.HostProvider` requires a saved Step, exact resource ID and
  incarnation, inspect after an uncertain create, and verified release.
  `HostRuntime` and core compatibility open admission only after a real BEAM
  node connects. See [contract](../../../lib/jido_cluster/host_provider.ex),
  [host guide](../../../guides/host-providers.md), and
  [Docker evidence](../06_host-providers/README.md).
- [FLAME's Fly backend](https://github.com/phoenixframework/flame/blob/2b124f3/lib/flame/fly_backend.ex)
  creates a machine with a random runner name, retries some failed create
  requests, waits for a runner callback, and links shutdown to its parent.
  [FLAME.Runner](https://github.com/phoenixframework/flame/blob/2b124f3/lib/flame/runner.ex)
  owns that lifecycle. [FLAME.Pool](https://github.com/phoenixframework/flame/blob/2b124f3/lib/flame/pool.ex)
  supports a positive minimum runner count and defaults to no idle shutdown
  for those minimum runners. A runner can also set `idle_shutdown_after:
  :infinity`. These are valid long-running hosts. The remaining seam is that
  the public work path does not expose a durable provider inspect/release API.
  A lost create reply can leave a machine outside Cluster's exact Step record.
  The runner node name includes a private address learned after creation,
  while current Cluster pools name hosts first. The
  [terminator](https://github.com/phoenixframework/flame/blob/2b124f3/lib/flame/terminator.ex)
  stops a runner when its parent process or node goes away. A laptop parent
  would make the demo worker stop when the laptop disconnects. The Fly backend
  can target a separate worker app and image. Its Machines do not inherit the
  parent's ordinary environment variables.
- [`sprites_ex`](https://github.com/superfly/sprites-ex/tree/c59c935) exposes
  create, get, list, destroy, command, and file operations. It returns a Sprite
  handle, but creates a general Linux sandbox, not a prepared BEAM host. The
  [Sprites proxy](https://docs.sprites.dev/api/dev-latest/proxy/) tunnels TCP
  through WebSocket; it does not by itself supply bidirectional Erlang node
  connectivity or a stable core checkpoint store. A
  [Sprite service](https://docs.sprites.dev/concepts/services/) restarts on a
  cold wake but does not stop a Sprite from pausing. The
  [Tasks API](https://docs.sprites.dev/keeping-sprites-running/) can hold it
  active; a live task needs refresh before its expiry. Even a warm pause drops
  TCP connections, so a service alone is not enough for an admitted BEAM node.
- On 2026-09-16, two disposable `eboss` Sprites ran OTP 28 and Elixir 1.19.2.
  Each joined Fly's private network with a WireGuard peer. DNS on that network
  resolved an existing `eboss` app, the Sprites pinged each other, and one
  Erlang node returned `pong` to `net_adm:ping/1` from the other over IPv6.
  Both Sprites and both WireGuard peers were removed. This proves Sprite to
  Sprite BEAM distribution over that network. It does not prove a Fly Machine
  to Sprite BEAM link, a Mix release, a Cluster host, or a Jido AI request.
- A [Mix release](https://mix.hexdocs.pm/Mix.Tasks.Release.html) includes the
  application code and ERTS by default. It needs the target Linux CPU and ABI;
  a release built on the laptop's macOS cannot run on a Sprite. A Sprite does
  not need Mix, Elixir, or Erlang installed when it runs a matching release.
  [Current new Sprites](https://docs.sprites.dev/sprite-maintenance/) use
  Ubuntu 25.10; check the exact OS and architecture on the demo Sprite. Build
  the Fly worker image and release on a matching Linux base, and check native
  libraries such as OpenSSL on both hosts before treating one artifact as
  portable.
  The Sprite create API has no source image or checkpoint field. Its
  [checkpoint API](https://docs.sprites.dev/concepts/checkpoints/) restores a
  saved filesystem on the same Sprite. A fresh Sprite still needs the release
  artifact and host network setup.
- [`Jido.AI.Agent`](../../../../jido_ai/lib/jido_ai/agent.ex) uses a normal core
  Agent and AgentServer. Its
  [request lifecycle](../../../../jido_ai/guides/user/request_lifecycle_and_concurrency.md)
  restores an interrupted streamed request as `:stream_interrupted`, with no
  live stream sink. Its
  [resume guide](../../../../jido_ai/guides/v3/20_checkpoint_resume.md)
  distinguishes saved conversation data from an execution checkpoint at a
  supported model or tool boundary. No current evidence proves that Cluster
  can move an active model call or replay an external tool effect.
- The current Cluster
  [Bedrock journal test](../../../test/jido_cluster/distributed/journal_bedrock_test.exs)
  uses one node and a local filesystem. Its
  [shared drain test](../../../test/jido_cluster/distributed/shared_drain_test.exs)
  uses shared Mnesia for Agent state. A three-host Bedrock client and repository
  layout has no current acceptance proof. For the first mixed-host demo, keep
  the Bedrock journal on the Fly control node and test a shared Mnesia Agent
  table with a disk copy on a Fly volume and RAM copies on workers. The table
  must survive a worker loss; the release must join it before HostRuntime
  admission. This is a proposed demo layout, not a proven remote deployment.
- [Fly app secrets](https://fly.io/docs/apps/secrets/) enter every Machine of
  that app as run-time environment variables, including API-created Machines.
  A separate worker app can hold model keys without giving them to the Phoenix
  control app. A Sprite can receive run-time environment values through its
  command or service start. The
  [Sprites connector gateway](https://docs.sprites.dev/concepts/connectors/)
  can instead keep an Anthropic key outside the Sprite, but it buffers model
  responses and has a 120-second upstream limit. ReqLLM compatibility with its
  base URL and header rules has not been tested.
- Fly's [Machines API](https://fly.io/docs/machines/api/machines-resource/)
  has inspect and delete by exact Machine ID. A laptop can join Fly's
  [private network](https://fly.io/docs/networking/private-networking/) with
  WireGuard. The existing Docker fixture proves the prepared-release shape,
  but not a Fly or Sprite worker.
- `fly orgs list` confirmed local access to `eboss` on 2026-09-16. Existing
  `eboss` apps were read only. Make dedicated demo apps; do not use a
  production app as a worker pool.

## Proposed contract and choices

Use one Cluster host admission and recovery contract for both providers. Use
`FLAME.FlyBackend` for Fly runners and `sprites_ex` for Sprite create, command,
file, and inspect operations. Each worker starts the same versioned Linux Mix
release with `jido`, `jido_ai`, `jido_cluster`, and their direct dependencies.
The release includes ERTS. A Sprite starts its release from a persistent path;
the live path has no `apt`, `mix deps.get`, compile, or `mix release` step.

FLAME owns Fly runner boot and execution. A Sprite service owns the prepared
Sprite worker process. Cluster owns topology placement, claims, drain, and
journal intent. Both host paths must report a connected node and external
resource identity to Cluster. The current FLAME backend does not give Cluster
a complete durable inspect/release contract. The first demo uses borrowed
hosts; owned acquisition follows after that seam is proven. A custom FLAME
Sprite backend is optional only if it improves the measured boot path and can
meet the Sprite task and identity rules. It is not a prerequisite for the
mixed-host demo.

The first milestone uses long-lived FLAME Fly runners and one prepared Sprite
as **borrowed** hosts for the video. The Fly controller starts one FLAME pool
per Fly worker slot with `min: 1`, `max: 1`, and
`min_idle_shutdown_after: :infinity`. The Sprite has the release and network
configuration installed before the recording. Its service starts the release
and its Tasks API heartbeat holds the Sprite active while its node carries
claims. The controller learns all connected node names before it starts the
Cluster scope with those nodes in its pool. Core and HostRuntime start under
the worker release's supervision tree. A long-lived core or HostRuntime must
not depend on `FLAME.place_child/3`, because that child follows its caller's
lifetime. Cluster can deploy and drain Agents. The UI identifies the Fly
Machines as FLAME-owned and the Sprite as pre-provisioned; Cluster cannot
claim it created or deleted those borrowed hosts. If a runner is replaced,
the new node stays outside the original claim until Cluster reconciles it.

The second milestone adds **owned** Cluster hosts. It needs the identity and
recovery work below, plus rules for automatic pool restart, Sprite service
restart, and Sprite pause. This is the path for Cluster Acquire/Release
buttons.

1. Keep `Jido.Cluster.HostProvider` as the only authority for owned Cluster
   hosts. A long-lived FLAME runner is a good candidate host. A direct
   `FLAME.call/3` is work execution; Cluster placement also needs the exact
   runner identity, claim guard, core, and durable ownership record.
2. Build a narrow FLAME integration spike that exposes a deterministic Step
   identity, one create attempt, exact Machine ID and incarnation, bounded
   inspection, and verified release. Use one long-lived runner per admitted
   host and disable idle shutdown while claims exist. A pool with `min: 1`
   starts and replaces runners on its own, so Cluster must fence its creation
   until journal intent is saved and must stop replacement when ownership is
   uncertain. This may need an upstream FLAME extension or a Cluster-owned Fly
   Machines adapter that reuses a prepared FLAME runner image and startup
   pattern. Decide from executable proof, not an adapter name. FLAME remains
   optional.
3. Add dynamic host admission or a proven stable node address before an owned
   Fly acquisition. Current `pools` require a BEAM node atom in configuration.
   Do not derive a new atom from an untrusted Machine response.
4. Build the direct `sprites_ex` host path around one prepared Sprite and its
   release service. Require two-way Erlang distribution, live task refresh,
   node readiness, and exact Sprite incarnation observation. A Sprite name
   alone is not an incarnation receipt. A cold restart closes admission until
   Cluster probes the new node and reconciles its retained claim. Start the
   WireGuard setup before the release service, pin the Erlang distribution
   port, and check the link after a warm wake. A warm wake keeps the process
   but drops old TCP links, so a failed rejoin must restart the worker service
   before admission.
5. Build the release once on matching Linux. Store a versioned artifact and
   checksum. Install it once on the persistent demo Sprite, keep its service
   definition, and verify a cold wake and release restart before recording.
   Build the Fly worker image from the same OS base as that Sprite. A release
   from an unrelated Fly image may fail because of its ABI or native libraries.
   A checkpoint can roll back that Sprite's filesystem; current create APIs
   do not clone it to a new Sprite. Measure both the pre-provisioned wake path
   and the slower new-Sprite download path separately.
6. Load `ANTHROPIC_API_KEY` or another provider key and `RELEASE_COOKIE` at
   worker boot, for example through `config/runtime.exs` for ReqLLM and release
   environment for distribution. Put Fly model keys in the dedicated worker
   app's secrets. Supply the Sprite key only to its trusted worker process;
   test a Sprites connector later for buffered calls, because its gateway
   does not stream model responses. Never put credentials in release artifacts,
   journal Steps, resource records, Agent state, or Phoenix event payloads.
   Run a key-presence probe that returns only true or false, then one bounded
   real model call on each host.
7. Use an application-owned Bedrock Repo for the Cluster journal on Fly. For
   the first demo, use a shared Mnesia Agent table with a disk copy on a Fly
   volume and RAM copies on workers. Test it across the Fly controller, Fly
   worker, and Sprite before recording the drain, including a worker restart.
   Keep a separate multi-host Bedrock proof before choosing Bedrock for Agent
   records. Wait for the AI request to reach a terminal state before moving
   the Agent. An interrupted stream is a failed request, not a continued one.

## Target requirements and proof

| ID | Required behavior | Acceptance proof |
| --- | --- | --- |
| CL-SANDBOX-REQ-001 | When Cluster acquires an owned sandbox, the provider shall bind one external resource to the saved Step before admission. | Lose create reply; inspect finds the same resource and no second create occurs. |
| CL-SANDBOX-REQ-002 | When a provider reports a running resource, Cluster shall admit its capacity only after the expected BEAM node, core, and HostRuntime identity pass. | Running but unconnected or wrong-code sandbox stays closed. |
| CL-SANDBOX-REQ-003 | If a source sandbox disconnects during drain, then Cluster shall retain its claim as uncertain. | Disconnect test shows no second writer on spare capacity. |
| CL-SANDBOX-REQ-004 | When all Agent and federation claims have retired, Cluster shall release only the recorded owned resource ID and incarnation. | Replace resource under same name; old release leaves replacement intact. |
| CL-SANDBOX-REQ-005 | When a Jido AI Agent moves after a planned drain, core persistence shall restore its accepted Ref and committed conversation state. | A second real model request on the other host uses the same Ref and cites the first request's committed tool result. |
| CL-SANDBOX-REQ-006 | When the demo records an AI request, the demo app shall keep its result separate from Cluster's best-effort Signal receipts. | LiveView shows request ID, checked node, model result, tool receipt, and a missing result after timeout. |
| CL-SANDBOX-REQ-007 | When a prepared Sprite starts its worker, the Sprite service shall run the matching Linux release without installing Erlang, Elixir, Mix, or dependencies. | Cold-wake test starts the release from the saved path and records time to HostRuntime readiness. |
| CL-SANDBOX-REQ-008 | While a Sprite carries a Cluster host claim, the Sprite worker shall refresh an active Tasks API hold before its expiry. | Leave the BEAM node idle beyond the Sprite pause interval; two-way distribution and the task remain active. |
| CL-SANDBOX-REQ-009 | When an AI request is active, the demo controller shall defer a planned Agent drain until that request reaches a terminal state. | Start a slow model request, press Drain, and observe that placement stays fixed until the terminal result. |
| CL-SANDBOX-REQ-010 | When a worker boots, the demo worker shall read model credentials from run-time configuration. | Release artifact scan finds no key; each host reports only key presence and completes one bounded model call. |
| CL-SANDBOX-REQ-011 | When a worker release connects, Cluster shall reject it if its code or persistence identity differs from the controller's expected values. | Boot a mismatched release or persistence config; admission stays closed. |

## Implementation steps

1. Add a small demo application with a `Jido.AI.Agent`, a read-only network
   check Action, a saved conversation history field, bounded model and tool
   budgets, and a local mock model test. Build a Linux x86_64 release that
   contains this app, core, AI, Cluster, FLAME, and ERTS. Start the artifact in
   a clean matching Linux container with no Elixir or Mix installed. Check
   runtime key loading, Erlang cookie, IPv6 distribution, and release identity.
2. Place the versioned artifact on one persistent Sprite before the demo.
   Install network setup once, define ordered network and release services,
   and add a Tasks API heartbeat with expiry and cleanup. Run warm-wake,
   cold-wake, idle-connectivity, and key-presence checks. Measure time from a
   start request to HostRuntime readiness. Keep a checksum and release
   revision visible in the UI.
3. Deploy a dedicated Fly control app and worker app in `eboss`. Put the model
   secret only in the worker app. Start one FLAME Fly runner. Prove Fly to Fly
   distribution, then Fly controller to Sprite distribution over the Sprite's
   WireGuard peer. Create and join the shared Agent table before HostRuntime
   admission. Confirm both workers can read and write it and run one bounded
   model request.
4. Run the borrowed mixed-host example: start Cluster after both worker node
   names are known, deploy the AI Agent, complete a model and tool request,
   drain the source after the request is terminal, then ask a second question
   on the other host. Verify the same Agent Ref, restored history, and a new
   model call. Record host, request ID, tool result, and answer without secrets.
5. Add the Phoenix LiveView in the control app. It sends bounded Cluster
   requests and reads status, claims, and lookup. It stores its own request
   rows by run ID and shows pending or uncertain operations. Keep the video
   path to a few actions: wake prepared hosts, ask, drain, ask again, inspect.
6. Write provider contract tests for lost create reply, exact observation,
   stale release, deletion confirmation, option validation, and time bounds.
   Keep external calls behind injectable clients in unit tests. Resolve
   FLAME's identity and ownership seam. Prefer a small upstream hook if it
   preserves FLAME's public contract. If it cannot, use the Fly Machines API
   for Cluster-owned hosts and keep FLAME for borrowed runner work.
7. Add owned Fly and Sprite acquisition only after the borrowed proof. Give
   each owned external create a saved Step, exact resource ID and incarnation,
   bounded inspection, and verified cleanup. Inspect all resources after the
   run. Do not present borrowed hosts as Cluster-owned in the UI.

## Living examples and promotion

Keep a credential-free `:example` case under `test/examples/12_sandboxes/`
with matching source and README under `examples/12_sandboxes/`. It should
exercise the real public Cluster APIs with a controlled provider and a local
mock model over real ReqLLM transport. Check a completed AI request, a drain,
and restored history under the same Ref. Add explicit Fly and Sprite acceptance
runners outside `mix test.all`, following the Docker pattern. Include a
no-credentials release boot test, an idle Sprite hold test, and a live bounded
model call on each host. Never count a fake-provider pass as proof of a remote
sandbox or a mock model result as proof of credential delivery.

Before promotion, run format, warnings-as-errors compile, unit, peer, example,
and provider contract tests. Run the explicit Fly and mixed-host acceptance in
`eboss`, inspect all resource IDs, and confirm cleanup. Report median and
slowest observed times for prepared Sprite wake, BEAM admission, first model
response, and a fresh Sprite artifact download separately. A fast prepared
Sprite does not prove fast fresh provisioning. Keep costs bounded with an
explicit machine count and a final inventory check.
