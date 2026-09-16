defmodule Jido.Cluster.Examples.AbruptDeathCleanup.Recorder do
  @moduledoc "Records events delivered to an acquired host."
  use Jido.Agent, name: "abrupt_death_cleanup_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/host_providers/abrupt_death_cleanup"

    route "examples.host_providers.abrupt_death_cleanup.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.AbruptDeathCleanup do
  @moduledoc "Recovers recorded host cleanup without deleting other resources."
  use Jido.Topology, name: "09_05_abrupt_death_cleanup", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.AbruptDeathCleanup.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.host_providers.abrupt_death_cleanup.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.AbruptDeathCleanup.Cluster do
  @moduledoc "Owns host requests, deployment claims, and the durable scope journal."
  use Jido.Cluster, otp_app: :jido_cluster
end
