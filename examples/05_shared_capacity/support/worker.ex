defmodule Jido.Cluster.Examples.SharedCapacity.Worker do
  @moduledoc "Records a committed count while placement and capacity change."
  use Jido.Agent, name: "shared_capacity_worker"

  agent do
    schema Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)})
  end

  routes do
    signal_source "/examples/shared_capacity/worker"

    route "examples.shared_capacity.worker.work" do
      action _input, context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
      end

      define :work
    end
  end
end
