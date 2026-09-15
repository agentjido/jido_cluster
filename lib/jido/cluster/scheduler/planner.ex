defmodule Jido.Cluster.Scheduler.Planner do
  @moduledoc """
  Plans complete admission for root singleton Topology Agents.

  Capacity is a slot budget for one Scheduler, not a global host reservation.
  Existing eligible placements are retained before new slots are selected.
  Groups, includes, and Plugin-added Agents are rejected in this first slice.
  """
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
  @spec plan(Instance.t(), [host()], [node()], map()) :: {:ok, map()} | {:error, term()}
  def plan(instance, hosts, draining \\ [], current \\ %{}) do
    with :ok <- validate_hosts(hosts),
         :ok <- validate_requirements(instance),
         :ok <- supported(instance) do
      hosts = Enum.reject(hosts, &(&1.node in draining))
      agents = Enum.sort_by(instance.definition.agents, & &1.key)
      {retained, remaining, budgets} = retain(agents, hosts, current, instance)

      with {:ok, desired} <- assign(remaining, hosts, budgets, retained, instance),
           :ok <- transition_capacity(hosts, current, desired),
           do: {:ok, desired}
    end
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

  defp supported(instance) do
    definition = instance.definition
    roots = Enum.map(definition.agents, &Topology.Plan.resolve(instance.plan, &1.key, :agent))

    if definition.groups == [] and definition.includes == [] and
         Enum.sort(roots) == Enum.sort(Map.keys(instance.plan.agents)),
       do: :ok,
       else: {:error, :unsupported_topology}
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
