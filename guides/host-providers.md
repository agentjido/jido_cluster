# Host providers

Status: draft for review. A host provider is an optional adapter for a
prepared BEAM runtime. Cluster records each acquisition or release step in
the durable scope journal. It uses the same host claims and deployment path
as a static worker. The provider does not own core Agent execution.

## Configure a prepared host

Give the host a normal pool record and one provider configuration. The
configured host node must be the node that the prepared runtime will use:

```elixir
worker_node = :"worker@host"

options = [
  journal: {Jido.Persistence.Bedrock, repo: MyApp.BedrockRepo},
  registry: my_registry,
  pools: [workers: [hosts: [
    %{node: worker_node, labels: ["compute"], capacity: 2, available: true}
  ]]],
  host_providers: %{
    worker_node => [
      id: "worker-pool",
      adapter: {MyApp.PreparedHostProvider, provider_options},
      ownership: :owned
    ]
  }
]
```

`my_registry` has stable IDs for the Topologies, Agents, and inputs that the
scope will save. `provider_options` holds adapter configuration. It does not
enter the journal. A provider needs a durable journal; `journal: :memory`
is rejected when `host_providers` is set. Configure `:borrowed` instead of
`:owned` for a resource that another owner created. Cluster releases its
claim on a borrowed resource but does not delete the resource.

The adapter implements `Jido.Cluster.HostProvider`. It must return a stable
resource ID and incarnation, bound its calls, and distinguish an absent
resource from an unavailable provider. A new owned runtime starts core and
`Jido.Cluster.HostRuntime` with the exact recorded provider step. Cluster
checks that runtime and core before it opens placement. A provider report by
itself does not make a host ready. See the
[contract](../lib/jido_cluster/host_provider.ex) and the
[acquired-host example](../examples/09_host_providers/09_01_acquired_topology/README.md).

## Acquire, use, and release

Request acquisition before deployment. Use a new request token for each new
operation:

```elixir
{:ok, acquire} =
  Jido.Cluster.acquire_host(MyApp.Cluster, worker_node,
    request_id: Jido.Cluster.request_id(MyApp.Cluster)
  )

{:ok, %{phase: :completed}} = Jido.Cluster.await(MyApp.Cluster, acquire.id)
{:ok, host} = Jido.Cluster.host_status(MyApp.Cluster, worker_node)
```

Check `host.admission` before you deploy. A lost provider reply is not
permission to acquire a second resource. Cluster inspects the original saved
step during explicit reconciliation and adopts only the same resource.
`host_status/2` reports saved intent and the current admission gate without
showing provider options.

Stop deployments and confirm Agent and channel cleanup before you expect a
release to complete:

```elixir
{:ok, stop} =
  Jido.Cluster.stop(MyApp.Cluster, "orders",
    request_id: Jido.Cluster.request_id(MyApp.Cluster)
  )

{:ok, %{phase: :completed}} = Jido.Cluster.await(MyApp.Cluster, stop.id)

{:ok, release} =
  Jido.Cluster.release_host(MyApp.Cluster, worker_node,
    request_id: Jido.Cluster.request_id(MyApp.Cluster)
  )

{:ok, %{phase: :completed}} = Jido.Cluster.await(MyApp.Cluster, release.id)
```

A release request first closes new admission. A live or uncertain claim keeps
the resource. An accepted provider release reply is not proof of deletion;
Cluster inspects the exact saved resource ID and incarnation before it records
release. It does not delete a newly discovered replacement under an old step.

The [five provider examples](../examples/09_host_providers/README.md) cover
acquisition, a lost reply, borrowed resources, release guards, and owner
death. They run on native peers with a controlled provider and real Bedrock.
The explicit Docker runners passed against a prepared worker image. Read the
[worker setup](../test/fixtures/docker_host/README.md) before a Docker run.
`Jido.Cluster.HostProvider.Docker` requires the optional `:req` dependency.
It accepts an exact Engine identity and a prepared image; it does not build
or pull the image. No provider contract here grants a partition-safe writer
lease.
