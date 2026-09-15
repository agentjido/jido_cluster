defmodule Jido.Cluster.Topology.Extension do
  @moduledoc "Adds static cluster_worker declarations to the core Topology agents section."

  alias Jido.Agent.Authoring

  defmodule Worker do
    @moduledoc "Static authoring value consumed by the cluster Topology extension."
    @type t :: %__MODULE__{key: atom(), module: module(), labels: [String.t()]}
    defstruct [:key, :module, :__spark_metadata__, labels: []]
  end

  @worker %Spark.Dsl.Entity{
    name: :cluster_worker,
    target: Worker,
    args: [:key, :module],
    schema: [
      key: [type: :atom, required: true],
      module: [type: :atom, required: true],
      labels: [type: {:list, :string}, default: []]
    ]
  }

  use Spark.Dsl.Extension,
    dsl_patches: [
      %Spark.Dsl.Patch.AddEntity{section_path: [:topology, :agents], entity: @worker}
    ]

  @behaviour Jido.Topology.Extension

  @doc "Lowers workers to ordinary Agents and records label requirements in Topology metadata."
  @spec lower_topology(map(), [struct()]) :: {:ok, map(), [struct()]} | {:error, Exception.t()}
  @impl Jido.Topology.Extension
  def lower_topology(config, entities) do
    {workers, rest} = Enum.split_with(entities, &match?(%Worker{}, &1))

    if Enum.any?(workers, fn worker -> Enum.any?(worker.labels, &(&1 == "")) end) do
      Authoring.error("Cluster labels must not be empty")
    else
      lower(config, workers, rest)
    end
  end

  defp lower(config, workers, rest) do
    agents = config.agents ++ Enum.map(workers, &%{key: &1.key, module: &1.module})
    rules = Map.new(workers, &{Atom.to_string(&1.key), &1.labels})
    existing = Map.get(config.metadata, "jido.cluster.requirements", %{})
    metadata = Map.put(config.metadata, "jido.cluster.requirements", Map.merge(existing, rules))
    {:ok, %{config | agents: agents, metadata: metadata}, rest}
  end
end
