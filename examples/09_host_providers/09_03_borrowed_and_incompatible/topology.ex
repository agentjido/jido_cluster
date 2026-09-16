defmodule Jido.Cluster.Examples.BorrowedAndIncompatible.Recorder do
  @moduledoc "Records events delivered to an acquired host."
  use Jido.Agent, name: "borrowed_and_incompatible_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/host_providers/borrowed_and_incompatible"

    route "examples.host_providers.borrowed_and_incompatible.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.BorrowedAndIncompatible do
  @moduledoc "Requires compatible capacity and preserves borrowed infrastructure."
  use Jido.Topology, name: "09_03_borrowed_and_incompatible", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.BorrowedAndIncompatible.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["examples.host_providers.borrowed_and_incompatible.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.BorrowedAndIncompatible.Cluster do
  @moduledoc "Owns host requests, deployment claims, and the durable scope journal."
  use Jido.Cluster, otp_app: :jido_cluster
end
