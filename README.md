# Jido Cluster V3

`jido_cluster` is an alpha runtime for named Topology deployments, bounded
domain-key entities on connected BEAM nodes. This branch is a local integration foundation. It is not ready for a
Hex release or production use.

## Local setup

Use the sibling V3 checkouts:

- `../jido` on `release/v3`
- `../jido_action` on `release/v3`
- `../jido_signal` with a compatible V3 version

`mix.exs` uses these paths with `override: true`. No environment switch or V2
fallback is used. Restore Hex requirements before a package release.

```sh
mise install
mise exec -- mix setup
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test --seed 0
mise exec -- mix quality
```

The `.tool-versions` file selects OTP 28 and Elixir 1.19. The normal test run excludes peer and example tests. Use `mix test.all`
to run all active tests. CI checks out the sibling V3 repositories before it builds.

## Guides

Start with the [V3 guide index](guides/README.md). It links to the named
deployment, journal recovery, federated Signal, host provider, and entity
guides. Each guide describes current behavior and links to a runnable
example. The [example catalog](examples/README.md) lists every scenario.

## Start a Cluster instance

```elixir
defmodule MyApp.Cluster do
  use Jido.Cluster, otp_app: :my_app
end

children = [
  {MyApp.Cluster, namespace: "my-app", journal: :memory, pools: []}
]
```

This starts a named scope and its local core Jido instance. Add configured
hosts before deploying work. Use `jido: MyApp.Core` to attach to a core that
your application already owns. Memory storage is for local use; configure
durable storage before relying on restart recovery.

## Named deployment and entity scopes

`use Jido.Cluster` defines a named scope. The scope admits declared Topologies
and [entity workloads](examples/10_entities/README.md) against the same host
claims and journal. An entity key maps to one versioned core Topology ID and
Ref. `Jido.Cluster.Entity.ensure/3` admits its first activation; `lookup/3`
does not start one. `call/5` waits for readiness and sends the Signal once.
The scope supports up to eight running entity identities and retains stopped
IDs in the journal.

Read [named deployments](guides/named-deployments.md) for the scope API and
[journal recovery](guides/recovery.md) before you configure durable storage.

## Durability

The Cluster journal stores the scope's deployment intent, claims, operation
results, and host resource identity. It uses `Jido.Persistence.Store` and
defaults to Bedrock with an application-owned Repo. Its stable identity is
`{namespace, scope}`; it contains all admitted Topologies in that scope.

Core Jido separately stores accepted Topology targets and Agent checkpoints.
Set `:agent_persistence` for managed core, or configure persistence on an
attached core. A durable Cluster journal alone does not persist Agent state.
The stores can share one backend, but their records and commits are separate.
See [journal and recovery](guides/recovery.md) for keys, setup, and failure rules.

See the [living examples](examples/README.md) and [local node testing guide](guides/testing.md).

The [design folder](docs/design/README.md) records implementation evidence,
proof limits, and proposals that still need review. Code and tests define
current behavior.

## Source layout

The public entry point is `lib/jido_cluster.ex`. Supporting modules are under
`lib/jido_cluster/`; their public namespace remains `Jido.Cluster`.

- `instance/` coordinates named scopes, deployment operations, and recovery.
- `admission.ex` and `drain.ex` manage shared claims and movement plans.
- `journal/` encodes durable intent, host sessions, and recovery records.
- `federation/` owns declared channels, transport, bindings, and their lifetime.
- `host_provider/` defines host resource contracts and the Docker adapter.
- `entity/` maps domain keys to core Topology identities without a second placement system.
- `topology/` defines the core Topology extension.
- `deployment.ex` and `deployment/` execute scope-confirmed placement and cleanup.
  They are internal; applications use the named Cluster facade.

Unit and peer tests are under `test/jido_cluster/`. Living example tests are
under `test/examples/` and use the `:example` tag.
