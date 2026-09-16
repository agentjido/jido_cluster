defmodule Jido.Cluster.Deployment.Planner do
  @moduledoc false
  alias Jido.Cluster.Federation.Declarations
  alias Jido.Cluster.Placement
  alias Jido.Topology
  alias Jido.Topology.Instance

  @type host :: %{node: node(), labels: [String.t()], capacity: non_neg_integer(), available: boolean()}

  @doc "Validates the configured host inventory, including unique nodes and slot budgets."
  @spec validate_hosts(term()) :: :ok | {:error, :invalid_inventory}
  def validate_hosts(hosts) when is_list(hosts) do
    capacities = Enum.all?(hosts, &match?(%{capacity: n} when is_integer(n) and n >= 0, &1))
    selection = Placement.select(:inventory, hosts)
    if capacities and selection != {:error, :invalid_inventory}, do: :ok, else: {:error, :invalid_inventory}
  end

  def validate_hosts(_hosts), do: {:error, :invalid_inventory}

  @doc "Selects every Agent before returning any admission; no processes are started."
  @spec plan(Instance.t(), [host()], [node()], map(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan(instance, hosts, draining \\ [], current \\ %{}, opts \\ []) do
    with :ok <- validate_hosts(hosts),
         :ok <- validate_requirements(instance),
         :ok <- supported(instance),
         :ok <- federation_supported(instance) do
      hosts = Enum.reject(hosts, &(&1.node in draining))
      agents = Enum.sort_by(instance.definition.agents, & &1.key)
      {retained, remaining, budgets} = retain(agents, hosts, current, instance)

      with {:ok, desired} <- assign(remaining, hosts, budgets, retained, instance),
           :ok <- federation_change(instance, current, desired, opts),
           :ok <- transition_capacity(hosts, current, desired),
           do: {:ok, desired}
    end
  end

  defp federation_change(instance, current, desired, opts) do
    if opts[:managed_federation], do: :ok, else: static_federation(instance, current, desired)
  end

  defp validate_requirements(instance) do
    requirements = Map.get(instance.definition.metadata, "jido.cluster.requirements", %{})
    keys = Enum.map(instance.definition.agents, & &1.key)

    if is_map(requirements) and Map.keys(requirements) -- keys == [] and
         Enum.all?(
           Map.values(requirements),
           &(Placement.select(:validation, [], &1) != {:error, :invalid_requirements})
         ),
       do: :ok,
       else: {:error, :invalid_requirements}
  end

  @doc "Builds a validated core instance with the selected exact nodes."
  @spec instantiate(Instance.t(), map()) :: {:ok, Instance.t()} | {:error, term()}
  def instantiate(instance, placements) do
    agents = Enum.map(instance.definition.agents, &Map.put(&1, :node, Map.fetch!(placements, &1.key)))

    with {:ok, definition} <- Topology.new(%{instance.definition | agents: agents}),
         do: Topology.instantiate(definition, id: instance.id, input: instance.input)
  end

  @doc "Validates an exact admitted placement without choosing another candidate."
  @spec validate_reservation(Instance.t(), [host()], map()) :: :ok | {:error, term()}
  def validate_reservation(instance, hosts, selected) when is_map(selected) do
    with :ok <- validate_hosts(hosts),
         :ok <- validate_requirements(instance),
         :ok <- supported(instance),
         :ok <- federation_supported(instance),
         true <- Enum.sort(Map.keys(selected)) == Enum.sort(Enum.map(instance.definition.agents, & &1.key)),
         true <- Enum.all?(instance.definition.agents, &reserved_eligible?(&1, instance, hosts, selected)),
         :ok <- transition_capacity(hosts, %{}, selected) do
      :ok
    else
      false -> {:error, :invalid_reservation}
      error -> error
    end
  end

  def validate_reservation(_, _, _), do: {:error, :invalid_reservation}

  defp reserved_eligible?(agent, instance, hosts, selected),
    do: Enum.any?(eligible(agent, hosts, %{}, instance), &(&1.node == Map.fetch!(selected, agent.key)))

  defp supported(instance) do
    definition = instance.definition
    roots = Enum.map(definition.agents, &Topology.Plan.resolve(instance.plan, &1.key, :agent))

    if definition.groups == [] and definition.includes == [] and
         Enum.sort(roots) == Enum.sort(Map.keys(instance.plan.agents)),
       do: :ok,
       else: {:error, :unsupported_topology}
  end

  defp federation_supported(instance) do
    with {:ok, _document} <- Declarations.read(instance.definition), do: :ok
  end

  @doc "Rejects channel placement changes until federation movement has a lifecycle protocol."
  @spec static_federation(Instance.t(), map(), map()) :: :ok | {:error, term()}
  def static_federation(instance, current, desired) do
    with {:ok, document} <- Declarations.read(instance.definition) do
      if document["channels"] == [] or current == %{} or current == desired,
        do: :ok,
        else: {:error, :federation_movement_not_implemented}
    end
  end

  defp retain(agents, hosts, current, instance) do
    Enum.reduce(agents, {%{}, [], %{}}, fn agent, {placed, remaining, budgets} ->
      worker = Map.get(current, agent.key)
      eligible = eligible(agent, hosts, budgets, instance)

      if Enum.any?(eligible, &(&1.node == worker)) do
        {Map.put(placed, agent.key, worker), remaining, reserve(budgets, worker)}
      else
        {placed, remaining ++ [agent], budgets}
      end
    end)
  end

  defp assign(agents, hosts, budgets, placed, instance) do
    Enum.reduce_while(agents, {:ok, placed, budgets}, fn agent, {:ok, placed, budgets} ->
      labels = labels(instance, agent)

      case Placement.select({instance.id, agent.key}, eligible(agent, hosts, budgets, instance), labels) do
        {:ok, worker} -> {:cont, {:ok, Map.put(placed, agent.key, worker), reserve(budgets, worker)}}
        {:error, :no_eligible_node} -> {:halt, {:error, {:no_capacity, agent.key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, placed, _budgets} -> {:ok, placed}
      error -> error
    end
  end

  defp eligible(agent, hosts, budgets, instance) do
    key = Topology.Plan.resolve(instance.plan, agent.key, :agent)
    spec = Map.fetch!(instance.plan.agents, key)
    requirements = labels(instance, agent)

    Enum.filter(hosts, fn host ->
      host.available and Map.get(budgets, host.node, 0) < host.capacity and
        is_list(requirements) and Enum.all?(requirements, &(&1 in host.labels)) and
        Placement.locality(spec, host.node, node()) == :ok
    end)
  end

  defp labels(instance, agent),
    do: instance.definition.metadata |> Map.get("jido.cluster.requirements", %{}) |> Map.get(agent.key, [])

  defp reserve(budgets, worker), do: Map.update(budgets, worker, 1, &(&1 + 1))

  defp transition_capacity(hosts, current, desired) do
    slots =
      (Map.to_list(current) ++ Map.to_list(desired)) |> Enum.uniq() |> Enum.map(&elem(&1, 1)) |> Enum.frequencies()

    incoming = desired |> Enum.reject(fn {key, worker} -> Map.get(current, key) == worker end) |> Enum.map(&elem(&1, 1))
    full = Enum.find(hosts, &(&1.node in incoming and Map.get(slots, &1.node, 0) > &1.capacity))
    if full, do: {:error, {:transition_capacity, full.node}}, else: :ok
  end
end
