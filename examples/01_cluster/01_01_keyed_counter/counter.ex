defmodule Jido.Cluster.Examples.KeyedCounter do
  @moduledoc "A keyed counter used to show cluster routing and checkpoint recovery."
  use Jido.Agent, name: "examples_cluster_keyed_counter"

  agent do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/examples/cluster/keyed_counter")

    route "examples.cluster.keyed_counter.increment" do
      action %{amount: amount},
        schema: Zoi.object(%{amount: Zoi.integer() |> Zoi.min(1)}),
        context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + amount}}
      end

      defaults(%{amount: 1})
      define(:increment, args: [{:optional, :amount}])
    end
  end
end
