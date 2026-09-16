alias Jido.Cluster
alias Jido.Cluster.Entity
alias Jido.Cluster.Examples.Entities.{Device, Scope}
alias Jido.Cluster.Journal

count = 8
namespace = "entity-benchmark/#{Jido.generate_id()}"
for table <- [:entity_benchmark_journal, :entity_benchmark_agents] do
  {:atomic, :ok} = :mnesia.create_table(table, attributes: [:key, :value], ram_copies: [node()])
end

journal = {Jido.Persistence.Mnesia, table: :entity_benchmark_journal}
agents = {Jido.Persistence.Mnesia, table: :entity_benchmark_agents}
{:ok, workload} = Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Device)
{:ok, topology} = Entity.topology(workload, {"devices", 1})
hosts = [%{node: node(), labels: [], capacity: count, available: true}]

{:ok, service} =
  Scope.start_link(
    namespace: namespace,
    journal: journal,
    agent_persistence: agents,
    registry: %{
      "schema/v1" => {:schema, topology.definition.schema},
      "device/v1" => {:agent, Device}
    },
    pools: [workers: [hosts: hosts]]
  )

times =
  for index <- 1..count do
    started = System.monotonic_time(:microsecond)
    {:ok, admitted} = Entity.ensure(Scope, workload, {"devices", index})
    {:ok, %{phase: :completed}} = Cluster.await(Scope, admitted.operation.id, 15_000)
    System.monotonic_time(:microsecond) - started
  end

{:ok, stored} = Journal.open(journal, {namespace, "default"})
bytes = byte_size(stored.expected)
times = Enum.sort(times)

IO.inspect(
  %{
    entity_count: count,
    active_claims: length(Cluster.claims(Scope)),
    total_activation_ms: Enum.sum(times) / 1000,
    median_activation_ms: Enum.at(times, div(count, 2) - 1) / 1000,
    max_activation_ms: List.last(times) / 1000,
    journal_bytes: bytes,
    journal_limit_bytes: Journal.limits().record_bytes,
    deployment_limit: Journal.limits().deployments
  },
  label: "entity activation bound"
)

:ok = Supervisor.stop(service)

for table <- [:entity_benchmark_journal, :entity_benchmark_agents] do
  {:atomic, :ok} = :mnesia.delete_table(table)
end
