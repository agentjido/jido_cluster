defmodule Jido.Cluster.Examples.Topologies.Counter do
  @moduledoc "A counter shared by the Topology placement lessons."
  use Jido.Agent, name: "examples_cluster_topologies_counter"

  agent do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/examples/cluster/topologies/counter")

    route "examples.cluster.topologies.increment" do
      action _input, context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
      end

      define(:increment)
    end
  end
end
