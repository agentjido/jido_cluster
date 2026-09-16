defmodule Jido.Cluster.Examples.LostAcquireReply.Recorder do
  @moduledoc "Records events delivered to an acquired host."
  use Jido.Agent, name: "lost_acquire_reply_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/host_providers/lost_acquire_reply"

    route "examples.host_providers.lost_acquire_reply.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.LostAcquireReply do
  @moduledoc "Runs a subscriber after recovery adopts its original host resource."
  use Jido.Topology, name: "09_02_lost_acquire_reply", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.LostAcquireReply.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.host_providers.lost_acquire_reply.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.LostAcquireReply.Cluster do
  @moduledoc "Owns host requests, deployment claims, and the durable scope journal."
  use Jido.Cluster, otp_app: :jido_cluster
end
