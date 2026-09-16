defmodule Jido.Cluster.Examples.ReleaseGuard.Recorder do
  @moduledoc "Records events delivered to an acquired host."
  use Jido.Agent, name: "release_guard_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/host_providers/release_guard"

    route "examples.host_providers.release_guard.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.ReleaseGuard do
  @moduledoc "Retains a host until binding cleanup and resource identity are confirmed."
  use Jido.Topology, name: "09_04_release_guard", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.ReleaseGuard.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.host_providers.release_guard.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.ReleaseGuard.Cluster do
  @moduledoc "Owns host requests, deployment claims, and the durable scope journal."
  use Jido.Cluster, otp_app: :jido_cluster
end
