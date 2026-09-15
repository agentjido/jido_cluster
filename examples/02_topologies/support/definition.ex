defmodule Jido.Cluster.Examples.Topologies.Definition do
  @moduledoc "Sets selected exact nodes in a core definition before common validation."
  @doc "Builds a core instance with exact placement for root singleton Agents."
  @spec build(module(), String.t(), map()) :: {:ok, Jido.Topology.Instance.t()} | {:error, term()}
  def build(module, id, placements) do
    definition = module.topology()

    agents =
      Enum.map(definition.agents, fn agent ->
        Map.put(agent, :node, Map.get(placements, agent.key, agent.node))
      end)

    attrs = definition |> Map.from_struct() |> Map.put(:agents, agents)

    with {:ok, selected} <- Jido.Topology.new(attrs),
         do: Jido.Topology.instantiate(selected, id: id)
  end
end
