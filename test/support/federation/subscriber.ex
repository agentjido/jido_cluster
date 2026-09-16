defmodule JidoCluster.Test.Federation.Subscriber do
  @moduledoc false
  use Jido.Agent, name: "federation_test_subscriber"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.any()) |> Zoi.default([])})
  end

  routes do
    route "counter.**" do
      action _input, context: context do
        event = Map.take(context.signal, [:id, :type, :source, :data])
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [event]}}
      end
    end
  end
end
