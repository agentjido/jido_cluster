defmodule JidoCluster.Test.PlacementWorker do
  @moduledoc "A worker that records committed work across placement changes."
  use Jido.Agent, name: "placement_example_worker"

  agent do
    schema(Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)}))
  end

  routes do
    signal_source("/examples/placement/worker")

    route "examples.placement.worker.work" do
      action _input, context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
      end

      define(:work)
    end
  end
end
