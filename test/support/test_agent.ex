defmodule JidoCluster.Test.CounterAgent do
  @moduledoc false
  use Jido.Agent, name: "jido_cluster_v3_counter"

  agent do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    route "inc" do
      action _params, context: context do
        {:ok, %{count: context.agent_state.count + 1}}
      end
    end
  end
end
