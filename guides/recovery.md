# Journal and recovery

Status: draft for review. This guide applies to named Cluster scopes.

Cluster stores request identity, deployment intent, claims, and operation
results in its scope journal. Core Jido stores Agent checkpoints and accepted
Topology targets in its own persistence adapter. Configure both stores when
you need committed state after a move or a service restart. A durable Cluster
journal alone does not make Agent state durable.

## Where records live

| Record | Owner and identity | Storage configuration |
| --- | --- | --- |
| Scope journal | Cluster; `{namespace, scope}` | `:journal`, defaulting to the Bedrock adapter |
| Accepted Topology target and placement | Core Jido; namespace and Topology ID | Core instance persistence |
| Agent checkpoint and commit revision | Core Jido; Agent Ref identity | Core instance persistence, subject to Agent overrides |

The journal is one bounded JSON aggregate for the whole scope, not a file or
record per Topology. Its adapter key is `jido:cluster:journal:v1:` followed by
the URL-safe SHA-256 digest of the JSON `[namespace, scope]` pair. Topology
definitions and input, desired running/stopped state, claims, request receipts,
federation intent, and provider resource identities live inside that aggregate.
The scope defaults to `"default"`; keep both scope and namespace stable.

Core uses separate keys with `jido:topology:v1:` and `jido:agent:v1:` prefixes.
The configured adapter decides where bytes physically live. For Bedrock, that
is the application-owned Repo's configured storage. For Mnesia, it is the
application-created table and its configured RAM or disk copies. Replicated
RAM copies alone do not survive loss of all nodes.

For managed core, `:agent_persistence` configures both core Topology target
storage and default Agent checkpoint storage. It does not inherit `:journal`.
For attached core, configure persistence when starting that core. The journal
and core records may use the same Repo or table, but do not share a transaction.
Runtime PIDs and supervisor processes are rebuilt; they are not saved processes.

## Shared storage boundary

`Jido.Cluster.Journal` uses `Jido.Persistence.Store.open/1`, `read/2`, and
`compare_and_swap/4`. Store validates the adapter, contains callback faults,
and returns the exact bytes or opaque token from a read as the next CAS
condition. Cluster never rebuilds that condition from decoded JSON.

Cluster still owns the journal key, versioned JSON, size limits, revision and
write-ID checks, and the decision to block external work. A conflict blocks
the old handle. An explicit `{:rejected, reason}` leaves it writable because
no write started. Both `:indeterminate` and `{:indeterminate, reason}` block
it until explicit reconciliation reads and confirms a new revision. No failed
write is replayed by Store or Journal.

Reads and writes emit core `[:jido, :persistence, :store, :start | :stop]`
telemetry. Metadata contains the operation, adapter, and result status;
it does not contain journal keys, values, tokens, or adapter options.

Use the core `Jido.Persistence.Mnesia` adapter for Mnesia. Cluster does not
provide a second Mnesia adapter. Existing table bytes and the journal's
`jido:cluster:journal:v1:` key format stay the same; update configuration
that used the removed Cluster adapter name. Core persistence configuration
continues to use the public `Jido.Persistence.resolve_config/2` contract.

## Choose storage explicitly

`journal: :memory` makes a scope for local use and tests. To retain scope
intent, supply a Jido persistence adapter and a trusted codec registry. For
example, an application can use a running Bedrock Repo for the journal and
Mnesia for Agent state:

```elixir
topology = MyApp.Workers.new!(id: "orders")

registry = %{
  "schema/workers-v1" => {:schema, topology.definition.schema},
  "worker/v1" => {:agent, MyApp.Worker},
  "node" => {:atom, :node}
}

cluster_options = [
  journal: {Jido.Persistence.Bedrock, repo: MyApp.BedrockRepo},
  registry: registry,
  agent_persistence: {Jido.Persistence.Mnesia, table: :agent_records}
]
```

The application starts the Repo and creates the shared Mnesia table before
the Cluster scope. Use stable registry IDs for every definition schema, Agent
module, and input value that the scope will save. A managed scope passes
`:agent_persistence` to its core. For an attached scope, configure persistence
on the application-owned core instead. See the
[adapter example](../examples/06_journal_recovery/06_04_adapter_choice/README.md)
for complete setup with Bedrock and Mnesia.

No configuration silently selects memory storage. A missing registry or
unavailable journal causes a startup or operation error. The journal has a
4,194,304-byte record limit and a 4,000,000-byte admission limit. Admission
checks the smaller limit before it starts work.

## Read an uncertain result

Cluster writes intent before it starts an operation. It records host identity
before it confirms a claim, and it writes a result before it reports
completion. A lost write reply can leave the result unknown even if storage
committed it. In this state, `status/1` can report
`:journal_unavailable`. Cluster blocks new mutations and retains all claims
that might be live. It does not select another host to hide the uncertainty.

Use these reads to understand the saved state:

| Read | What it tells you |
| --- | --- |
| `Jido.Cluster.status(scope)` | Scope health, recovery progress, and limits |
| `Jido.Cluster.operation(scope, id)` | The retained result of one accepted operation |
| `Jido.Cluster.status(scope, topology_id)` | Desired state and current deployment readiness |
| `Jido.Cluster.claims(scope)` | Reserved, active, and uncertain host demand |

An operation that completed before a restart does not prove that its Agent is
ready now. An `await/3` timeout does not cancel work. Do not submit a new
business Signal to compensate for a timeout without an application-level
check of its result.

## Start explicit recovery

On service restart, running or unfinished intent starts at
`:reconciliation_required`. Call `reconcile/1` on the original scope:

```elixir
:ok = Jido.Cluster.reconcile(MyApp.Cluster)
scope_status = Jido.Cluster.status(MyApp.Cluster)
{:ok, deployment_status} = Jido.Cluster.status(MyApp.Cluster, "orders")
```

`:ok` means that Cluster accepted the recovery pass. It does not mean that
the pass is complete. Check `scope_status.recovering` and the current
deployment readiness. Recovery confirms a new journal revision and checks
prior ownership and host claims before it starts a replacement. If cleanup
is unconfirmed, the relevant claims remain uncertain. Work that uses
independent capacity can continue.

Recovery can complete an interrupted drain with the saved source and target
reservation. It keeps the source claim charged until target readiness and
confirmed source release. If placement changed before the restart, Core
persistence must retain the accepted target. Without it, Cluster reports
`:placement_restore_requires_persistence` and does not guess a target.

Stopped intent stays stopped after restart. An expired request token remains
expired, but active deployment claims remain. An uncertain request can fill
the bounded retention epoch and cause `:retention_saturated`. No recovery
operation replays a Signal or grants a disconnected writer a new lease.

Read the [recovery examples](../examples/06_journal_recovery/README.md) for
an interrupted drain, an unknown write reply, an uncertain source, and two
real journal adapters. The [placement guide](named-deployments.md) gives the detailed
claim and request limits.
