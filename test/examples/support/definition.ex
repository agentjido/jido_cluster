defmodule JidoCluster.Examples.Support.Definition do
  @moduledoc false
  @doc "Builds a core instance with exact placement for root singleton Agents."
  @spec build(module(), String.t(), map()) :: {:ok, Jido.Topology.Instance.t()} | {:error, term()}
  def build(module, id, placements) do
    definition = module.topology()

    # Group 02 tests supply application placement policy explicitly. Rewrite a
    # copy of the root declarations; keep the source module's definition intact.
    agents =
      Enum.map(definition.agents, fn agent ->
        Map.put(agent, :node, Map.get(placements, agent.key, agent.node))
      end)

    attrs = definition |> Map.from_struct() |> Map.put(:agents, agents)

    # Rebuild through core validation after selecting exact nodes. Location may
    # change, but the same Topology ID still gives each Agent its logical ID.
    with {:ok, selected} <- Jido.Topology.new(attrs),
         do: Jido.Topology.instantiate(selected, id: id)
  end
end
