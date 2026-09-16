defmodule Jido.Cluster.Examples.UncertainAttachment.Recorder do
  @moduledoc "Retains committed event IDs through uncertain target attachment."
  use Jido.Agent, name: "federation_uncertain_attachment_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/federation_lifecycle/uncertain_attachment"

    route "examples.federation_lifecycle.uncertain_attachment.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.UncertainAttachment do
  @moduledoc "Declares a required subscriber that follows accepted placement."
  use Jido.Topology, name: "08_04_uncertain_attachment", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.UncertainAttachment.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.federation_lifecycle.uncertain_attachment.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.UncertainAttachment.Cluster do
  @moduledoc "Owns the subscriber's journal and movement requests."
  use Jido.Cluster, otp_app: :jido_cluster
end
