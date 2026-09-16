defmodule Jido.Cluster.Examples.BridgeRestart.Recorder do
  @moduledoc "Records event IDs before and after bridge repair."
  use Jido.Agent, name: "federation_bridge_restart_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/federation_lifecycle/bridge_restart"

    route "examples.federation_lifecycle.bridge_restart.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.BridgeRestart do
  @moduledoc "Declares a subscriber whose channel can be repaired at the same placement."
  use Jido.Topology, name: "08_02_bridge_restart", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.BridgeRestart.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.federation_lifecycle.bridge_restart.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.BridgeRestart.Cluster do
  @moduledoc "Owns the subscriber's journal and explicit repair requests."
  use Jido.Cluster, otp_app: :jido_cluster
end
