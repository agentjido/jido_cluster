# Package purpose and proposed top-level API

Status: proposed. Written on 2026-09-15. All new functions, structs, provider
modules, configuration, and DSL syntax below require implementation and tests.
The [alignment review](alignment.md) identifies the current runtime separately.

## Purpose

`jido_cluster` should let an application deploy a core Jido topology onto
suitable BEAM hosts and retain control of its placement lifecycle. It selects
capacity, acquires hosts when needed, submits exact-node activation to core,
tracks location, and coordinates movement, recovery, and release.

Host intelligence supplies validated facts about compatible capacity. Optional
Signal federation connects local event Buses across hosts and follows Agent
placement. Reports and events remain separate from admission claims and authority.

The application declares what runs and where it may run. Cluster placement
turns that request into a ready deployment. Callers use stable Agent Refs while
placement changes.

A concrete use case is a coding team with a coordinator on existing application
nodes and workers on dedicated Docker or hosted BEAM runtimes. The same Agent
definitions can use static hosts in local tests and acquired hosts in deployment.

The adoption pitch is: **declare a topology and its placement requirements;
let Jido Cluster obtain suitable capacity and manage where its Agents run.**

## Capability boundary

| Capability | Proposed responsibility | First supported scope |
| --- | --- | --- |
| Deployment | Admit a core topology and wait for core readiness | Root singleton Agents |
| Placement | Select a named target and an eligible host | Labels, compatible runtime, integer Agent slots |
| Dynamic capacity | Acquire a host through a provider and release owned capacity | Local Docker proof before a hosted backend |
| Routing | Resolve and send work through stable core Agent Refs | Agents owned by a managed topology |
| Operations | Plan, move, drain, stop, inspect, and reconcile | Serialized operations with explicit uncertainty |
| Recovery | Repair workers and reconcile interrupted placement | Connected hosts; bounded attempts |
| Ownership | Exclude competing connected topology coordinators | Connected coordination, separate from write authority |
| Host intelligence | Observe health, compatibility, workload, and capacity with freshness evidence | Bounded reports and stable eligibility; no automatic load-driven movement |
| Signal federation | Forward selected events between local Buses and follow Ref subscription bindings | Opt-in best-effort channels after placement and directory proofs |

Groups, includes, Plugin-added Agents, shared target budgets, provider restart
reconciliation, and durable operation records are required later slices. Each
must pass its proof gate before it becomes a supported contract.

Automatic rebalance, rolling upgrades, region policy, and richer resource budgets
can extend this model later. Partition-safe host replacement requires protected
write authority and a core replacement contract. Spare capacity alone cannot
authorize replacement of an unreachable source.

General sandbox tool execution, file APIs, terminals, conversation sessions,
model integration, business retries, and durable workflows are separate concerns.
The connected mode assumes hosts run trusted application releases. An environment
used only to execute tool code is an application resource, not automatically a
topology host.

## Ownership and dependencies

| Owner | Contract |
| --- | --- |
| `jido_action` | Actions and executable values |
| `jido_signal` | Signal envelopes, serialization, local Bus semantics, and generic transport adapters |
| `jido` | Agent identity, execution, state, checkpoint format, local supervision, core topology validation, exact-node activation, and readiness |
| `jido_cluster` | Placement requirements, host intelligence, admission, location directory, placement owners, provider operations, federated channel bindings, bridge lifecycles, and cluster status |
| Provider backend | Existing-host access or acquired-host lifecycle and resource observations |
| Application | Trusted runtime images, persistence deployment, target configuration, tenant policy, and external-effect handling |
| Authority service and protected storage | Grants and atomic rejection of stale writers when exclusive replacement is required |

Keep `jido_cluster` dependent on core Jido. An application can combine it with
`jido_ai`; AI is not required for ordinary Agent placement. An acquired host
may run an application that includes AI dependencies, without the control-plane
package depending on those dependencies.

`Jido.Session` in the current AI package is an interaction value that owns a
Thread. A compute resource needs its own placement handle. Neither interaction
history nor an AI request record should own the host lifecycle.

## Terms and identity

| Value | Meaning |
| --- | --- |
| Topology instance | A validated core definition, input, and stable topology ID |
| Deployment | The cluster-managed lifecycle of that topology instance |
| Agent Ref | The exact core namespace, optional partition, and ID |
| Target | A named capacity source with a provider and placement policy |
| Host | A concrete runtime resource with a cluster host ID and incarnation |
| Provider handle | Resource identity and lifecycle data needed to inspect or release a host |
| Location | A versioned observation of an Agent's node, host, process, and readiness |
| Host report | Versioned runtime and capacity observations, with provenance and freshness |
| Federated channel | An explicitly scoped event channel with local Bus mirrors and host interest |
| Operation | One accepted deployment or placement change, identified separately from its attempts |
| Authority | Permission to perform protected writes; distinct from every value above |

The proposed facade takes the configured cluster service as its first argument.
Topology IDs are core instance IDs. The logical deployment scope is the exact
core namespace and topology ID. A service name is a local entry point; it must
not create a second owner for that same logical scope.

Host IDs are opaque values assigned by cluster placement. Store the provider
resource identity and incarnation separately. Reusing a hostname or provider
name must not let an old release request destroy a newer resource.

Agent IDs come from the core plan. Do not derive another cluster checkpoint ID.
The existing manager/key encoding remains unchanged until its mapping to core
Refs is explicitly designed.

## Configuration and DSL

The following is proposed configuration. Start the cluster service after the
local Jido instance. Use an application supervision boundary where the Jido
instance outlives its cluster service.

```elixir
children = [
  {MyApp.Jido, []},
  {Jido.Cluster,
   name: MyApp.Cluster,
   jido: MyApp.Jido,
   default_target: :control,
   budget_scope: :deployment,
   targets: [
     control: [
       provider: {Jido.Cluster.Provider.Static,
         hosts: [
           %{node: node(), labels: ["control"], capacity: 4, available: true}
         ]}
     ],
     isolated_elixir: [
       provider: {Jido.Cluster.Provider.Docker,
         image: "my-app/jido-workers:release-123"},
       max_hosts: 4,
       agents_per_host: 1,
       labels: ["compute"]
     ]
   ]}
]
```

Targets are runtime configuration. Images, credentials, host access, and provider
options stay there. The provider selects or validates an existing prepared
runtime; topology authoring does not install application dependencies.

`budget_scope: :deployment` makes each deployment's limits explicit. Supporting
`:cluster` requires the shared admission authority in slice D; it must be rejected
until that slice is implemented. Do not present deployment-scoped limits as a
shared provider or cluster limit.

`max_hosts` bounds acquired hosts within the selected budget scope.
`agents_per_host` defines integer Agent slots, not measured CPU or memory
guarantees. An unbound worker uses the explicit
`default_target`. An unknown target is an error. Dedicated placement uses one
Agent slot per acquired host; shared hosts require explicit configuration.

The recommended DSL keeps core Agent declarations and placement bindings separate:

```elixir
defmodule MyApp.CodingTeam do
  use Jido.Topology,
    name: "coding_team",
    extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      agent :coordinator, MyApp.Coordinator
      agent :coder, MyApp.Coder
    end

    placements do
      place :coordinator, on: :control
      place :coder, on: :isolated_elixir, labels: ["compute"]
    end
  end
end
```

The extension statically records bindings in portable topology metadata. It
does not acquire sessions, start processes, or contact a provider. Normal core
validation still applies. Runtime planning checks target existence and supported
requirements before acquisition. Duplicate bindings and invalid binding keys
must fail explicitly.

The existing `cluster_worker` syntax can remain a convenience for Agent
declaration plus placement metadata. Its label-only behavior must remain
compatible. Named targets and the separate `placements` section are new work.

Group and include bindings require explicit expansion and inheritance rules.
Do not silently treat a group key as one Agent slot or start an expanded worker
locally before applying its requested initial placement.

## Top-level API

All signatures below are proposed. Standard `child_spec/1` and `start_link/1`
support service supervision. The API does not expose a second Agent runtime.

### Deploy and use

| Call | Result and meaning |
| --- | --- |
| `plan(cluster, instance)` | `{:ok, Plan}` or `{:error, Error}`. Read-only preview against a versioned inventory observation; no acquisition or reservation. |
| `deploy(cluster, instance, opts)` | `{:ok, Operation}` after accepting an initial deployment request; this does not mean ready. |
| `status(cluster, topology_id)` | `{:ok, DeploymentStatus}` or `{:error, Error}`. Desired placement, accepted core placement, observed readiness, capacity claims, and operation IDs. |
| `ref(cluster, topology_id, key)` | `{:ok, Jido.Agent.Ref}` from the validated core plan; no activation. Group member selection is a later extension. |
| `resolve(cluster, ref)` | `{:ok, Location}` or `{:error, Error}`. Resolve a managed Ref without starting an Agent; reject an uncertain location. |
| `call(cluster, ref, signal, opts)` | `{:ok, Jido.Agent}` after a committed core call, or `{:error, Error}`. Route through the current location without automatic Signal replay. |
| `cast(cluster, ref, signal)` | `{:ok, :submitted}` after submitting a best-effort asynchronous send through core, or `{:error, Error}` for a known routing failure. No acknowledgement that an Agent received, executed, or persisted it. |

The cast wrapper must preserve core's best-effort send semantics. A routing
acknowledgement is not an Agent mailbox acknowledgement. A stronger confirmed
enqueue API would require a separate runtime contract and proof.

### Inspect and change placement

| Call | Result and meaning |
| --- | --- |
| `hosts(cluster, target)` | `{:ok, [HostStatus]}` with host IDs, readiness, claims, and provider observations. |
| `host_report(cluster, host_id)` | `{:ok, HostReport}` with compatibility, resource observations, provenance, and freshness, or `{:error, Error}`. Does not trigger movement. |
| `move(cluster, ref, opts)` | `{:ok, Operation}` for a cooperative move to the named target in `opts[:to]`. Reject an unreachable source without confirmed replacement authority. |
| `drain(cluster, host_id, opts)` | `{:ok, Operation}` after admitting evacuation of the host. Exclude it from new placement and retain that intent until settled. |
| `stop(cluster, topology_id, opts)` | `{:ok, Operation}` for stopping the deployment, retaining Agent persistence, and releasing unused owned capacity. |
| `operation(cluster, key)` | `{:ok, Operation}` with state, attempts, progress, and errors. `key` is an operation ID or `{:request, request_id}` for an acceptance response that was lost. |
| `await(cluster, operation_id, opts)` | `{:ok, Operation}` on success or `{:error, Error}` on failure, uncertainty, or wait timeout. A wait timeout does not cancel the operation. |
| `reconcile(cluster, operation_id, opts)` | `{:ok, Operation}` for one bounded reconciliation attempt on the existing operation. Inspect evidence before resubmitting provider work. |

Placement-changing calls require a caller-selected binary `request_id`. Bind it
to the namespace, action, and normalized payload. Repeating the same request
returns the same operation; a different payload with that ID returns a conflict.
Reconciliation retains the logical operation ID and records a new attempt ID.
Read calls and Signal delivery do not use placement request IDs as deduplication
keys for application work. After an acceptance timeout, look up the original
request with `operation(cluster, {:request, request_id})`; do not invent a fresh
request ID to resolve the unknown result.

An initial deployment accepts an unused topology ID. Changed definitions,
resources, removals, and rolling updates to an existing deployment are outside
the first API slice. They need an explicit target-update contract, not an
implicit interpretation of another `deploy` call.

### Optional federated events

The separate [Signal federation contract](signal-federation.md) proposes
`publish/4`, `subscribe/5`, `unsubscribe/2`, and `federation_status/2` on the
cluster facade. These calls manage explicit channels and Ref bindings. A publish
acknowledges local append and outbound submission, not remote delivery or Agent
commit. Existing core local Bus bindings keep their current semantics.

```elixir
alias Jido.Cluster

{:ok, instance} = MyApp.CodingTeam.new(id: "team-123")
{:ok, preview} = Cluster.plan(MyApp.Cluster, instance)
{:ok, deployment} =
  Cluster.deploy(MyApp.Cluster, instance, request_id: "team-123-deploy")

{:ok, _completed} =
  Cluster.await(MyApp.Cluster, deployment.id, timeout: 15_000)

{:ok, coder} = Cluster.ref(MyApp.Cluster, instance.id, :coder)
{:ok, agent} = Cluster.call(MyApp.Cluster, coder, work_signal, timeout: 5_000)

{:ok, shutdown} =
  Cluster.stop(MyApp.Cluster, instance.id, request_id: "team-123-stop")

{:ok, _completed} =
  Cluster.await(MyApp.Cluster, shutdown.id, timeout: 15_000)
```

`work_signal` is an application-created `Jido.Signal`. `preview` is explanatory
data; admission must recheck inventory when `deploy` runs. A preview is not a
capacity promise.

### Returned data and errors

The named structs are proposed public values. Define portable formats before
persisting them. Runtime observations may include a PID; portable location and
operation records must exclude PIDs, Tasks, links, closures, and credentials.

| Value | Required fields |
| --- | --- |
| `Plan` | Topology ID, definition identity, inventory/report revisions, budget scope, target bindings, selected or proposed acquisition slots, candidate explanations, constraints, and ordered steps |
| `DeploymentStatus` | Namespace, topology ID, desired revision, budget scope, phase, accepted placements, observed locations, capacity claims, active operations, and error |
| `Location` | Core Ref, host ID, incarnation, node, observation revision, readiness, and optional runtime PID |
| `HostStatus` | Target, host ID, incarnation, provider resource identity, state, compatibility/report summary, slot claims, and release state |
| `HostReport` | Identity, reporter generation, sequence, compatibility, aggregate workload, resource measurements, freshness evidence, and provenance |
| `FederationStatus` | Deployment scope, channels, host interest, binding revisions, bridge/link state, queue usage, and drops |
| `Operation` | ID, request ID, namespace, topology IDs, action, state, attempt history, steps, durability mode, timestamps, and error |
| `Error` | Kind, reason, relevant Ref or topology ID, request ID when supplied, and operation ID when known |

Error kinds are `:rejected`, `:failed`, and `:uncertain`. Rejection means the
requested change was not accepted. Failure reports a known failed step and its
remaining resources. Uncertainty means an effect or cleanup result cannot yet
be established. Operations retain partial progress; none of these words implies
automatic rollback.

Initial reasons should cover invalid requirements, unsupported topology shape,
unknown target or Ref, insufficient capacity, incompatible runtime, local resource
constraints, request conflict, coordinator unavailability, uncertain placement,
uncertain delivery, and uncertain cleanup. A timeout after request submission
must return uncertainty with the request ID available for lookup.

## Placement providers

Use a small native provider contract rather than importing a general sandbox
facade. LitterBox is useful prior art for resource identity and backend lifecycle.
Its compute-session concept is different from Jido interaction sessions.

The proposed provider boundary has three operations:

```text
acquire(request, context) -> {:ok, handle} | {:error, error}
status(key, context)      -> {:ok, observation} | {:error, error}
release(handle, context) -> :ok | {:error, error}
```

`request` names the required prepared runtime and capacity. `context` contains
trusted target configuration, a parent cluster operation ID, and a stable provider
resource-step ID. Multiple host acquisitions in one deployment need distinct
resource-step IDs. `status` accepts either a resource identity or that resource-step
ID, so a timed-out acquisition can be inspected before its handle is known.

Acquire must bind the resource-step ID to its payload. Repeating that step must
find the same resource or report uncertainty; it must not silently create another
host. Release must verify the resource incarnation and distinguish relinquishing
an application-owned host from destroying a cluster-owned host.

| Provider | Initial behavior |
| --- | --- |
| Static | Select configured existing nodes; release cluster claims without stopping the application-owned host |
| Docker | Start a prepared Jido release, observe its resource and node, and remove only owned containers after Agent cleanup |
| Hosted runtime | Implement the same observation, readiness, reconciliation, and release requirements before promotion |
| FLAME integration | Define the supervised child and pool relationship explicitly before using FLAME runner capacity |

The provider's resource-ready observation is not Agent readiness. Cluster must
also verify node connectivity, exact namespace, release compatibility, required
node-local services, and persistence configuration. Core then reports topology
readiness. A sandbox HTTP endpoint alone is not a core placement node.

Snapshotting a filesystem does not replace a core Agent checkpoint. Do not restore
one provider's snapshot on another provider unless that backend contract explicitly
supports it. Provider lifecycle holds do not establish protected-write authority.

LitterBox backend code can inform implementation. Copying code, adding LitterBox
as a dependency, and implementing native provider calls remain separate choices.
Any extraction must retain the relevant resource-ownership and cleanup rules.

## Host intelligence and federation

[Host intelligence](host-intelligence.md) turns runtime facts into explainable
eligibility. Use bounded direct probes, report generations, and explicit unknown
measurements. Slot claims remain admission data; observed low load cannot grant
extra slots. Existing healthy placements remain stable until an accepted operation
changes them.

[Signal federation](signal-federation.md) is an optional distributed resource
contract. Each host retains local Buses. Cluster-owned bridges route only selected
events to interested hosts and update Ref bindings after movement. Keep loop
prevention, bounded queues, and best-effort loss explicit. A local durable
subscription does not establish durable cross-host delivery.

Host reports may produce lifecycle notifications through federation. Admission
uses the validated host view and claims directly. Lost events cannot revoke or
grant capacity, establish host death, or authorize replacement of an old writer.

## Lifecycle and failure rules

Keep one cluster lifecycle owner and one manual core Controller per deployment.
A supervised placement owner holds provider resources and operation tasks. A
temporary request Task or AI request coordinator must not own a long-lived host.

1. Validate the definition, bindings, requirements, and resource locality.
2. Admit the complete initial topology against the configured budget.
3. Record operation and resource-step identities before provider side effects.
4. Acquire required hosts and verify runtime compatibility.
5. Apply selected exact nodes through core and wait for readiness.
6. Publish versioned locations and report deployment success.
7. On move or stop, settle core cleanup before releasing unused owned hosts.

Complete admission does not make deployment transactionally atomic. A later boot
can fail. Keep the operation, partial resource claims, and cleanup results visible.
Do not report a completed stop or drain while required cleanup is uncertain.

Retain existing eligible placements. During movement, claim both source and target
slots until source retirement and target readiness are established. Reject a move
without transition capacity rather than briefly exceeding the budget.

First retain today's per-deployment budgets. Shared target limits require one
admission authority for the configured scope and tests with competing deployments.
Independent node-local counters do not enforce a shared cluster limit. Host drain
across deployments is supported only after this shared scope is proved.

Desired placement, effective accepted core placement, and observed live process
state are different values. After restart or partial movement, read the public
core accepted placement and check live readiness before publishing a location.
Do not treat a cached plan as evidence that a worker moved.

Worker failure on a connected host may request bounded manual repair. Provider
failure, owner-process failure, parent-node failure, and authority failure need
separate recovery decisions. An unreachable source stays uncertain in connected
mode. Operator reconciliation can inspect evidence; it cannot override that rule
with a timeout or a force flag.

No cluster operation replays Agent Signals. Calls can have unknown outcomes;
application deduplication or explicit business retry policy belongs above placement.

### Operation durability

Operation states distinguish accepted, admitting, acquiring, activating, moving,
releasing, succeeded, failed, and uncertain. Uncertainty blocks conflicting work
until one recorded reconciliation attempt establishes the next safe step.

A static first slice may expose memory-only operation records and declare that
restart loses those records. Lookup must report that evidence is unavailable,
not report a lost operation as successfully completed.

Dynamic providers and restart-safe operations require a durable cluster journal.
Record desired revision, request binding, attempts, acquired resource identities,
capacity claims, drain intent, and acknowledged release steps. This journal records
placement work; it does not become a business workflow engine or replace Agent
persistence. Journal durability does not provide partition-safe write authority.

On restart, reconcile journal records with core accepted targets and provider
observations. If these disagree or evidence is unavailable, preserve claims and
report uncertainty. Never repeat an unknown acquisition using a fresh ID.

## Tests and living examples

Write contract tests before runtime work. Keep executable examples under
`test/examples/`, with `@moduletag :example` and matching source under `examples/`.
The normal unit suite excludes examples. Do not add separate demo scripts.

| Proof | Test level | Required observation |
| --- | --- | --- |
| Static DSL lowering | Unit | Ordinary core Agents and portable bindings; no provider side effects |
| Requirement validation | Unit | Unknown targets, duplicate bindings, unsupported capabilities, and invalid shape fail explicitly |
| Request identity | Unit | Same payload and ID return one operation; changed payload conflicts |
| Initial admission | Unit and peer | An unadmitted topology starts no Agent or provider acquisition |
| Cross-node routing | Peer and example | Two callers use one core Ref and observe one committed state sequence |
| Directory after move | Peer and example | Identity remains stable; location revision and observed node change |
| Competing coordinators | Peer and example | One connected owner; the rejected owner starts no Controller |
| Provider acquisition timeout | Provider contract | Status by resource-step ID finds the resource or reports uncertainty; no duplicate create |
| Owner death during boot | Provider contract and peer | Resources are cleaned or retained as explicitly uncertain |
| Partial activation | Peer | Failed deployment reports every acquired host and cleanup outcome |
| Interrupted drain | Peer and example | Completed steps remain recorded; remaining source and target claims stay accurate |
| Controller and coordinator restart | Peer and example | Accepted placement and readiness are reread; operations use the declared durability mode |
| Shared budget | Peer | Competing deployments cannot exceed one configured target limit |
| Shared-host release | Provider contract and example | Stopping one topology does not destroy capacity used by another |
| Hosted pause or reboot | Provider contract | Lost processes and connections are detected; checkpoint restore and readiness precede routing |
| Host report freshness | Unit and peer | Retired incarnations, old sequences, and late or replayed probes cannot restore eligibility |
| Host pressure | Unit and example | Unknown resource values stay unknown; transient load does not cause repeated movement |
| Federated channels | Peer and example | Scope, interested-host delivery, original Signal identity, and loop prevention hold |
| Federated movement | Peer and example | Ref bindings reattach after movement; delivery gaps and uncertain cleanup match the selected mode |
| Federation failure | Peer and example | Bounded queues, bridge restart, and disconnect do not alter placement authority |
| Protected-write replacement | Authority fault tests | A superseded writer is rejected after partition, delayed disconnect, and restart |

Build five living examples in order:

1. **Static deployment API:** plan, deploy, await, route by Ref, inspect, and stop.
2. **Dedicated Docker worker:** acquire a host, activate one worker, commit work,
   stop, and verify container release.
3. **Two deployments, one budget:** prove shared admission and shared-host retention.
4. **Move across targets:** drain a connected static host to Docker, retain core
   identity and checkpoint state, and verify source cleanup.
5. **Interrupted placement:** kill the owner after acquisition or during drain,
   restart, reconcile recorded work, and prove no duplicate host or false success.

Hosted and FLAME examples follow the same provider contract suite. Authority tests
are a separate gate; connected examples cannot establish partition safety.

The companion documents add host-eligibility, shared-host, pressure-observation,
three-host federation, moved-subscription, and bridge-failure examples. These are
proposed test cases, not additional runnable examples in the current suite.

## Delivery slices and open decisions

| Slice | Deliverable | Gate before promotion |
| --- | --- | --- |
| A | Topology facade, named static targets, pure bindings, Ref directory, basic host reports, and explicit memory-only operations | Existing foundation stays green; static API, routing, compatibility, and report-freshness examples pass |
| B | Cluster journal, provider resource-step identity, and restart reconciliation | Unknown acquisition, owner loss, restart, and interrupted cleanup tests pass |
| C | Native Docker provider with dedicated hosts | Full provider suite and Docker lifecycle example pass |
| D | Shared target admission, shared hosts, and scope-wide drain | Competing-deployment and shared-host cleanup tests pass |
| E | Expanded topology placement and additional providers | Core initial-placement seam and each provider's compatibility tests pass |
| F | Authorized lost-source replacement | Protected-write authority and core replacement contract are proved |
| G | Optional best-effort Signal federation with local mirrors and Ref bindings | Scope, host interest, loops, movement, bounded queues, and bridge-failure tests pass |

Slice G depends on the placement and Ref-directory contracts in A. It can be
developed after A without claiming the authority guarantees in F. Shared-host
federation cleanup also needs the shared admission and lifecycle scope in D.

Recommendations in this document are not accepted API decisions. Record decisions
with reason, alternatives, affected packages, and passing evidence before promotion.

- **API-01:** Use a topology-first facade. Keep the keyed manager separate until
  identity and lifecycle mapping is designed.
- **API-02:** Use named runtime targets and a separate static placement section.
  Inline `cluster_worker` placement remains a possible convenience form.
- **API-03:** Use a narrow native provider contract. Decide dependency versus
  extraction for each backend separately; do not import the full sandbox API.
- **API-04:** Keep the package independent of AI. Hosts can still run AI Agents.
- **API-05:** Require recorded request and resource-step identities. Dynamic
  providers require journal-backed restart reconciliation before promotion.
- **API-06:** Start with dedicated acquired hosts. Shared hosts need a separate
  admission and release proof.
- **API-07:** Preserve uncertainty. No implicit Signal replay, forced retirement,
  or partition-safety claim follows from provider success.
- **API-08:** Treat host intelligence as validated observations plus bounded
  policy. No model dependency or independent host repair loop is required.
- **API-09:** Support Signal federation as an optional cluster service. Preserve
  local Bus behavior and start with explicitly scoped best-effort events.

Still open: the journal adapter and admission authority, exact metadata format,
binding inheritance, release compatibility identity, and the smallest core seam
for initial placement of expanded plans. A confirmed enqueue API is separate from
the proposed best-effort cast wrapper.

Host-report units, probe policy, channel protocol, runtime subscription durability,
and any stronger federation delivery mode remain separate open decisions in the
companion designs.
