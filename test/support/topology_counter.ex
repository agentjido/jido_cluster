defmodule JidoCluster.Test.TopologyCounter do
  @moduledoc "A counter shared by the Topology placement lessons."
  use Jido.Agent, name: "examples_cluster_topologies_counter"

  agent do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/examples/cluster/topologies/counter")

    route "examples.cluster.topologies.increment", as: :increment do
      action _input, context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
      end
    end
  end

  def increment_signal! do
    {:ok, signal} = increment_signal(%{})
    signal
  end
end
