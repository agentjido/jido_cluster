defmodule Jido.Cluster.Examples.Deployment.Worker do
  @moduledoc "Records one committed work count through the named deployment service."
  use Jido.Agent, name: "deployment_worker"

  agent do
    schema Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)})
  end

  routes do
    signal_source "/examples/deployment/worker"

    route "examples.deployment.worker.work" do
      action _input, context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
      end

      define :work
    end
  end
end
