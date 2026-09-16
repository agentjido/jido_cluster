defmodule Jido.Cluster.Examples.EnvelopeAndLoops.Recorder do
  @moduledoc "Records the original event fields through the normal Agent handler."
  use Jido.Agent, name: "federation_envelope_and_loops_recorder"

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
    signal_source "/examples/federation/envelope_and_loops"

    route "examples.federation.envelope_and_loops.record" do
      action _input, schema: Zoi.object(%{value: Zoi.integer()}), context: context do
        event = Map.take(context.signal, [:id, :type, :source, :data])
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [event]}}
      end

      define :record, args: [:value]
    end
  end
end

defmodule Jido.Cluster.Examples.EnvelopeAndLoops do
  @moduledoc "Declares the scoped event channel and its required local subscribers."
  use Jido.Topology, name: "07_02_envelope_and_loops", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :first, Jido.Cluster.Examples.EnvelopeAndLoops.Recorder, labels: ["origin"]
      cluster_worker :second, Jido.Cluster.Examples.EnvelopeAndLoops.Recorder, labels: ["destination"]
    end

    resources do
      federated_channel(:events, types: ["examples.federation.envelope_and_loops.record"])
    end

    connections do
      federated_subscribe(:first, to: :events)
      federated_subscribe(:second, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.EnvelopeAndLoops.Cluster do
  @moduledoc "Owns this example's fixed-host deployment scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
