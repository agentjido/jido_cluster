defmodule Jido.Cluster.Examples.ProviderLifecycle.Recorder do
  @moduledoc "Retains committed events across deployment movement and recovery."
  use Jido.Agent, name: "system_provider_lifecycle_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/system/provider_lifecycle"

    route "examples.system.provider_lifecycle.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.ProviderLifecycle do
  @moduledoc "Declares a subscriber on the shared worker allocation."
  use Jido.Topology, name: "11_02_provider_lifecycle", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.ProviderLifecycle.Recorder, labels: ["shared"]
    end

    resources do
      federated_channel(:events, types: ["examples.system.provider_lifecycle.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.ProviderLifecycle.Cluster do
  @moduledoc "Owns the subscriber's journal and movement requests."
  use Jido.Cluster, otp_app: :jido_cluster
end

defmodule Jido.Cluster.Examples.ProviderLifecycle.Independent do
  @moduledoc "Declares a subscriber on the independent worker allocation."
  use Jido.Topology, name: "11_02_independent", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.ProviderLifecycle.Recorder, labels: ["independent"]
    end

    resources do
      federated_channel(:events, types: ["examples.system.provider_lifecycle.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end
