defmodule Jido.Cluster.Examples.InterestedEvents.Recorder do
  @moduledoc "Records the original event fields through the normal Agent handler."
  use Jido.Agent, name: "federation_interested_hosts_recorder"

  agent do
    schema Zoi.object(%{
             events:
               Zoi.list(
                 Zoi.object(%{
                   id: Zoi.string(),
                   type: Zoi.string(),
                   source: Zoi.string(),
                   data: Zoi.object(%{value: Zoi.integer()})
                 })
               )
               |> Zoi.default([])
           })
  end

  routes do
    signal_source "/examples/federation/interested_hosts"

    route "examples.federation.interested_hosts.record" do
      action _input, schema: Zoi.object(%{value: Zoi.integer()}), context: context do
        event = Map.take(context.signal, [:id, :type, :source, :data])
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [event]}}
      end

      define :record, args: [:value]
    end
  end
end

defmodule Jido.Cluster.Examples.InterestedEvents do
  @moduledoc "Declares the scoped event channel and its required local subscribers."
  use Jido.Topology, name: "07_01_interested_hosts", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.InterestedEvents.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.federation.interested_hosts.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.InterestedEvents.Cluster do
  @moduledoc "Owns this example's fixed-host deployment scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
