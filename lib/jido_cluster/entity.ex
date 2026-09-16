defmodule Jido.Cluster.Entity do
  @moduledoc """
  Bounded on-demand entity activation in one Cluster capacity scope.

  Each identity is one root singleton core Topology. The scope service admits
  it through the same journal, host claims, activation, drain, and recovery as
  declared topology demand. First requests are serialized by that service.
  A domain-key hash never selects a host or starts an Agent.

  One scope admits at most eight running entity identities, in addition to
  the journal's shared limit of 16 deployments. Stopped IDs remain journaled
  and cannot be started again in the same scope. This is a bounded workload,
  not an unbounded entity cache.

  """

  alias Jido.Cluster
  alias Jido.Cluster.Entity.Identity
  alias Jido.Cluster.Instance.Service
  alias Jido.Topology

  @agent_key "entity"
  @max_active 8
  @enforce_keys [:definition_id, :keyspace, :agent, :requirements, :initial_state]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          definition_id: String.t(),
          keyspace: String.t() | nil,
          agent: module(),
          requirements: [String.t()],
          initial_state: map()
        }

  @doc "Validates one immutable workload definition."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    definition_id = Keyword.get(opts, :definition_id)
    keyspace = Keyword.get(opts, :keyspace)
    agent = Keyword.get(opts, :agent)
    requirements = Keyword.get(opts, :requirements, [])
    initial_state = Keyword.get(opts, :initial_state, %{})

    with :ok <- validate_options(opts, agent, requirements, initial_state),
         {:ok, _} <- Identity.id(definition_id, keyspace, sample_identity(keyspace)),
         workload = %__MODULE__{
           definition_id: definition_id,
           keyspace: keyspace,
           agent: agent,
           requirements: requirements,
           initial_state: initial_state
         },
         {:ok, _} <- topology(workload, sample_identity(keyspace)) do
      {:ok, workload}
    end
  end

  def new(_), do: {:error, :invalid_entity_workload}

  @doc "Returns the mapping version and per-scope active identity limit."
  @spec limits() :: map()
  def limits, do: Map.put(Identity.limits(), :active_per_scope, @max_active)

  @doc "Builds the exact core singleton Topology for one domain identity."
  @spec topology(t(), term()) :: {:ok, Topology.Instance.t()} | {:error, term()}
  def topology(%__MODULE__{} = workload, identity) do
    with {:ok, id} <- Identity.id(workload.definition_id, workload.keyspace, identity),
         {:ok, definition} <-
           Topology.new(%{
             name: workload.definition_id,
             agents: [%{key: @agent_key, module: workload.agent, initial_state: workload.initial_state}],
             metadata: %{
               "jido.cluster.entity" => %{"version" => 1, "definition_id" => workload.definition_id},
               "jido.cluster.requirements" => %{@agent_key => workload.requirements}
             }
           }),
         do: Topology.instantiate(definition, id: id)
  end

  @doc "Returns the stable core Ref without activating an Agent."
  @spec ref(atom(), t(), term()) :: {:ok, Jido.Agent.Ref.t()} | {:error, term()}
  def ref(instance, %__MODULE__{} = workload, identity) do
    with {:ok, topology} <- topology(workload, identity),
         {:ok, config} <- Cluster.config(instance) do
      spec = Map.fetch!(topology.plan.agents, "agent/" <> @agent_key)
      Jido.agent_ref(config.jido, spec.id)
    end
  end

  @doc "Admits or finds one activation. Concurrent first requests share one operation."
  @spec ensure(atom(), t(), term()) :: {:ok, map()} | {:error, term()}
  def ensure(instance, %__MODULE__{} = workload, identity) do
    with {:ok, topology} <- topology(workload, identity),
         do: Service.call(instance, {:entity_ensure, topology})
  end

  @doc "Looks up an accepted entity without starting it."
  @spec lookup(atom(), t(), term()) :: {:ok, map()} | {:error, term()}
  def lookup(instance, %__MODULE__{} = workload, identity) do
    with {:ok, topology} <- topology(workload, identity),
         do: Service.call(instance, {:entity_lookup, topology})
  end

  @doc "Admits the entity and calls core once after readiness. A timeout never replays a Signal."
  @spec call(atom(), t(), term(), Jido.Signal.t(), timeout()) :: term()
  def call(instance, workload, identity, signal, timeout \\ 5_000)

  def call(instance, workload, identity, %Jido.Signal{} = signal, timeout)
      when is_integer(timeout) and timeout > 0 do
    with {:ok, %{operation: operation, ref: ref}} <- ensure(instance, workload, identity),
         :ok <- await_ready(instance, operation, timeout),
         do: Cluster.call(instance, ref, signal, timeout)
  end

  def call(_instance, _workload, _identity, _signal, _timeout), do: {:error, :invalid_entity_call}

  @doc false
  @spec topology?(term()) :: boolean()
  def topology?(%Topology.Instance{definition: %{metadata: metadata}, plan: %{agents: agents}})
      when is_map(metadata) and is_map(agents) do
    match?(%{"version" => 1, "definition_id" => id} when is_binary(id), metadata["jido.cluster.entity"]) and
      map_size(agents) == 1 and Map.has_key?(agents, "agent/" <> @agent_key)
  end

  def topology?(_), do: false

  defp sample_identity(nil), do: "sample"
  defp sample_identity(keyspace), do: {keyspace, "sample"}

  defp validate_options(opts, agent, requirements, initial_state) do
    keys = [:definition_id, :keyspace, :agent, :requirements, :initial_state]

    valid? =
      Keyword.keyword?(opts) and Keyword.keys(opts) -- keys == [] and
        length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
        valid_fields?(agent, requirements, initial_state)

    if valid?, do: :ok, else: {:error, :invalid_entity_workload}
  end

  defp valid_fields?(agent, requirements, initial_state),
    do:
      valid_agent?(agent) and valid_requirements?(requirements) and
        is_map(initial_state) and not is_struct(initial_state)

  defp valid_agent?(agent), do: is_atom(agent) and agent not in [nil, true, false]

  defp valid_requirements?(requirements),
    do: is_list(requirements) and Enum.all?(requirements, &(is_binary(&1) and &1 != ""))

  defp await_ready(_instance, %{phase: :completed}, _timeout), do: :ok

  defp await_ready(instance, %{id: id, phase: :accepted}, timeout) do
    case Cluster.await(instance, id, timeout) do
      {:ok, %{phase: :completed}} -> :ok
      {:ok, %{phase: :uncertain}} -> {:error, :uncertain}
      {:ok, %{phase: :failed, reason: reason}} -> {:error, {:activation_failed, reason}}
      {:ok, _} -> {:error, :pending}
      {:error, :timeout} -> {:error, :pending}
      {:error, _} = error -> error
    end
  end

  defp await_ready(_instance, %{phase: :uncertain}, _timeout), do: {:error, :uncertain}
  defp await_ready(_instance, %{phase: :failed, reason: reason}, _timeout), do: {:error, {:activation_failed, reason}}
  defp await_ready(_instance, _operation, _timeout), do: {:error, :pending}
end
