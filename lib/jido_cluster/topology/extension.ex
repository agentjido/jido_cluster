defmodule Jido.Cluster.Topology.Extension do
  @moduledoc "Adds static worker, federated channel, and subscription declarations to core Topology."

  alias Jido.Agent.Authoring
  alias Jido.Cluster.Federation.Declarations

  defmodule Worker do
    @moduledoc "Static authoring value consumed by the cluster Topology extension."
    @type t :: %__MODULE__{key: atom(), module: module(), labels: [String.t()]}
    defstruct [:key, :module, :__spark_metadata__, labels: []]
  end

  defmodule Channel do
    @moduledoc "Static channel declaration with an explicit list of allowed Signal types."
    @type t :: %__MODULE__{key: atom() | String.t(), types: [String.t()]}
    defstruct [:key, :__spark_metadata__, types: []]
  end

  defmodule Subscription do
    @moduledoc "Static root Agent subscription to a federated channel."
    @type t :: %__MODULE__{agent: atom() | String.t(), to: atom() | String.t(), required: boolean()}
    defstruct [:agent, :to, :__spark_metadata__, required: true]
  end

  @channel %Spark.Dsl.Entity{
    name: :federated_channel,
    target: Channel,
    args: [:key],
    schema: [key: [type: :any, required: true], types: [type: {:list, :string}, required: true]]
  }
  @subscription %Spark.Dsl.Entity{
    name: :federated_subscribe,
    target: Subscription,
    args: [:agent],
    schema: [
      agent: [type: :any, required: true],
      to: [type: :any, required: true],
      required: [type: :boolean, default: true]
    ]
  }

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
      %Spark.Dsl.Patch.AddEntity{section_path: [:topology, :agents], entity: @worker},
      %Spark.Dsl.Patch.AddEntity{section_path: [:topology, :resources], entity: @channel},
      %Spark.Dsl.Patch.AddEntity{section_path: [:topology, :connections], entity: @subscription}
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
    {channels, rest} = Enum.split_with(rest, &match?(%Channel{}, &1))
    {bindings, rest} = Enum.split_with(rest, &match?(%Subscription{}, &1))

    with {:ok, lowered} <- Declarations.lower(%{config | agents: agents, metadata: metadata}, channels, bindings),
         do: {:ok, lowered, rest}
  end
end
