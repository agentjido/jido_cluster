defmodule JidoCluster.Test.DockerHost.Recorder do
  @moduledoc false
  use Jido.Agent, name: "docker_host_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    route "docker.record" do
      action _input, context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end
    end
  end
end
