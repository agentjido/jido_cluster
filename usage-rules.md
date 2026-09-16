# Jido Cluster V3 usage rules

Define a named OTP instance with `use Jido.Cluster, otp_app: :my_app` and put
it in the application supervision tree. Omit `:jido` to own a core instance,
or supply an already running core through `:jido`.

Use core Topologies with `Jido.Cluster.Topology.Extension`. Deploy through
`Jido.Cluster`; use `Jido.Cluster.Entity` for bounded domain-key workloads.
Both use the same scope capacity, journal, drain, and recovery path.

Use `Jido.Persistence.Store` for journal bytes and core-owned adapters such as
`Jido.Persistence.Mnesia`. Cluster owns the journal format and recovery policy.
Configure the Cluster journal and core Agent persistence separately. The
journal defaults to Bedrock; the application supplies its Repo and trusted
registry. Explicit `journal: :memory` is temporary. Use stable namespace,
scope, Topology IDs, and entity definition IDs across restarts.

Use request tokens for deployment operations. Route business Signals through
core Refs. A timeout is an unknown result, not permission to replay a Signal.
An unreachable host is not proof of death. Reconcile saved intent before
replacing an uncertain activation.

Use compatible sibling Jido V3 dependencies for local integration. The
internal deployment runtime is not a separate application-facing scheduler.
