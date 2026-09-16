# Delivery slices

Status: high-level plan recorded on 2026-09-15. Architecture and package scope
reflect the agreed direction. Module names, signatures, storage format, transport,
and supervisor restart strategies remain proposals for detailed slice planning.
No slice below is marked complete by this documentation change.

## Direction and decisions

Build one package that deploys core Jido topologies, manages host capacity, and
provides the federated Signal channels those deployments require. Use optional
backend integrations. Useful Fabric capabilities can become internal modules.

| Decision | Reason and alternative | Proof gate |
| --- | --- | --- |
| Core topology is the workload contract | Reuse core identity and lifecycle rather than create a second graph/runtime | S1 validates unsupported forms before side effects |
| One package with optional capabilities | Reduce required packages rather than require Fabric and separate adapter packages | Base and optional-dependency checks in each applicable slice |
| Shared admission before acquired hosts | Establish capacity ownership before infrastructure failure states | S2 concurrent admission and shared cleanup |
| Record intent before restart-safe claims | Memory-only operations cannot preserve drain intent through restart | S3 interruption and journal recovery |
| Federation before acquired-host providers | Distributed topologies need cross-host event bindings | S4–S5 scope, movement, and failure proofs |
| Core keeps Agent execution and persistence | Avoid duplicate checkpoint and runtime semantics | Existing core contract tests plus consumer integration tests |

Primary changes belong in `jido_cluster`. Any missing generic core or Signal
contract must be demonstrated by a failing integration test and changed in its
own package. No core change is assumed merely to add a provider or facade.

## Code seams

| Proposed seam | Responsibility |
| --- | --- |
| `Jido.Cluster` | `use` macro, named OTP instance, managed/attached core mode, and deployment entry points |
| `Topology.Extension` | Pure lowering of placement and federation metadata |
| `Planner` | Deterministic candidate selection and explanatory plans |
| `Admission` | Shared claims, transition capacity, and mutation serialization |
| `Hosts` / `HostSession` | Inventory, incarnation, eligibility, ownership, and observations |
| `HostProvider` | Acquire, inspect by request/resource identity, and release |
| `Deployment` / `DeploymentOwner` | One placement owner and manual core Controller per topology instance |
| `Journal` | Record protocol on core persistence adapters; Bedrock by default; intent, claims, and operation progress |
| `Directory` | Managed core Ref to observed ready location |
| `Federation` / `ChannelBridge` | Scoped forwarding, host interest, bounds, and health |
| `SubscriptionBindings` | Stable Ref bindings and host-local attachment lifecycle |
| `FederationTransport` | Optional cross-host transmission adapter |

Extract useful behavior from the current Scheduler. Do not replace tested owner
cleanup with an unproved automatic restart path. The current keyed manager stays
separately scoped until S7 establishes compatibility and common admission.

## Proposed process ownership

```text
Application.Supervisor
├── Application repositories and infrastructure clients
├── MyApp.Jido (attached mode only)
├── Cluster host runtime (on each participating host)
│   └── FederationSupervisor
│       ├── Transport connection, if required
│       └── ChannelSupervisor per local channel mirror
│           ├── Local Signal Bus
│           ├── ChannelBridge
│           └── Local subscription bindings
└── MyApp.Jido.Cluster (named control instance)
    ├── Underlying core Jido instance (managed mode only)
    ├── Registry
    ├── Journal access/reconciliation boundary
    ├── HostSupervisor
    │   └── HostSession per tracked host
    ├── Admission
    ├── OperationSupervisor
    │   └── Bounded operation tasks
    └── DeploymentSupervisor
        └── DeploymentOwner per topology instance
            ├── Deployment coordinator
            └── Core Controller ownership boundary
                └── Jido core Controller
```

The instance is declared with `use Jido.Cluster, otp_app: :my_app` and added to
supervision as `MyApp.Jido.Cluster`. Without `jido:`, it owns the underlying core
instance. With `jido: MyApp.Jido`, it attaches to the separately supervised instance
and never owns that instance's shutdown. Core must outlive dependent cleanup in
both modes. Validate names, namespace parity, configuration precedence, and scope
ownership before side effects. See the [instance and journal vision](README.md).

This is an ownership sketch, not a final child-spec implementation. The journal
may use an application-owned repository without a dedicated process. Core owns
Agent supervision on each host. A deployment owner tracks remote resources; it
does not supervise remote processes through a local DynamicSupervisor.

Host sessions outlive individual deployment tasks and can serve several
deployments. Channel mirrors are scoped by namespace, topology ID, and channel;
transport connections may be shared. Stop removes only the requesting deployment's
bindings and unused resources. No requester Task owns a long-lived host.

On loss of admission state, block mutations until claims are reconstructed.
Controller replacement waits for ownership cleanup. Host or coordinator loss
retains uncertainty. Define restart ordering and failure behavior in each slice;
do not rely on supervisor restart alone for correctness or partition safety.

## Cross-slice planning gates

Read [the lifecycle contracts](lifecycle-contracts.md) before implementing S1.
Define operation identity and journal boundaries alongside S1/S2; S3 supplies the
durable implementation. Establish the peer host handshake in S1 and reuse it in
S6. Run S7's bounded identity/topology mapping probe before S2/S3 schemas are fixed;
full entity functionality remains S7. This is design dependency work, not permission
to claim later slices complete.

S5 promotion includes the cumulative static system example. S6 adds a real-provider
variant. The process tree describes ownership, not a guarantee that remote workers
survive control-process failure. Confirm cleanup before restoring running intent.

## Build entry point

Start with [build readiness](build-readiness.md). It lists the decisions to close
through S1 tests, the later numeric/backend gates, and the final source-review
refinements. The seven-slice order is unchanged.

## Ordered slices

Each slice owns its scope and future detailed plan in a separate folder.
Read and implement in this order; dependencies are stated in each entry.

| Slice | Planning folder | Status |
| --- | --- | --- |
| S1 | [Static topology deployment service](../01_instance-and-deployment/README.md) | Slice implementation and tests pass; see plan evidence |
| S2 | [Shared admission and host drain](../02_admission-and-drain/README.md) | Slice implementation and tests pass; see plan evidence |
| S3 | [Journal and restart reconciliation](../03_journal-and-recovery/README.md) | Slice implementation and tests pass; see plan evidence |
| S4 | [Scoped federation on static hosts](../04_signal-federation/README.md) | Slice implementation and tests pass; see plan evidence |
| S5 | [Federation through movement and restart](../05_federation-lifecycle/README.md) | Slice implementation and tests pass; see plan evidence |
| S6 | [Acquired host ownership and one provider](../06_host-providers/README.md) | Local implementation and real Docker acceptance pass; see the S6 audit |
| S7 | [Entity capabilities from Fabric](../07_entity-capabilities/README.md) | Bounded implementation and local acceptance pass; see S7 evidence |

## Example acceptance

Use the [shared example test method](example-testing.md) and the scenario matrix
in each slice plan. Proposed example groups 04–10 map to S1–S7. These are required
proofs, not claims of existing test coverage.

## Detailed planning process

Plan one slice at a time. Each detailed plan must include:

1. Public behavior, supported scope, and explicit exclusions.
2. Input/output contracts and configuration validation.
3. Process ownership, restart order, and operation state transitions.
4. Persistence and optional-dependency requirements.
5. Failure matrix: rejection, known failure, timeout, and uncertainty.
6. Unit tests, local peer tests, and one or more tagged living examples.
7. Migration impact and any separately scoped core or Signal change.
8. Promotion criteria and documentation updates.

Write contract tests before implementation. Use isolated local Erlang nodes for
distributed proofs. Keep living tests under `test/examples/` with `:example`,
matching source folders under `examples/`, and no separate demo runners. Explain
why assertions and readiness barriers exist. Run the package's relevant checks
before promotion and keep optional backend absence in the test matrix.

Current evidence remains in the placement guide (retired path: `../../../guides/placement.md`)
and [alignment review](../90_reference/02_top-level-api/alignment.md). Those establish parts of
the foundation, not completion of these shared-service and federation slices.

Deferred beyond this plan: expanded topology forms, automatic scaling/rebalancing,
load-driven policy, durable federation, replica protocols, and partition-safe
writer replacement. Each needs a separate contract and proof gate.
