defmodule Jido.Cluster.Examples.AcquiredTopology.Recorder do
  @moduledoc "Records events delivered to an acquired host."
  use Jido.Agent, name: "acquired_topology_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/host_providers/acquired_topology"

    route "examples.host_providers.acquired_topology.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.AcquiredTopology do
  @moduledoc "Runs a subscriber on capacity accepted by a host provider."
  use Jido.Topology, name: "09_01_acquired_topology", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.AcquiredTopology.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.host_providers.acquired_topology.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.AcquiredTopology.Cluster do
  @moduledoc "Owns host requests, deployment claims, and the durable scope journal."
  use Jido.Cluster, otp_app: :jido_cluster
end
