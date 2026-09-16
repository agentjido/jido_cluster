defmodule Jido.Cluster.Examples.DeploymentLifecycle.Recorder do
  @moduledoc "Retains committed events across deployment movement and recovery."
  use Jido.Agent, name: "system_deployment_lifecycle_recorder"

  agent do
    schema Zoi.object(%{events: Zoi.list(Zoi.string()) |> Zoi.default([])})
  end

  routes do
    signal_source "/examples/system/deployment_lifecycle"

    route "examples.system.deployment_lifecycle.record" do
      action _input, schema: Zoi.object(%{}), context: context do
        {:ok, %{context.agent_state | events: context.agent_state.events ++ [context.signal.id]}}
      end

      define :record
    end
  end
end

defmodule Jido.Cluster.Examples.DeploymentLifecycle do
  @moduledoc "Declares a subscriber on the shared worker allocation."
  use Jido.Topology, name: "11_01_deployment_lifecycle", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.DeploymentLifecycle.Recorder, labels: ["shared"]
    end

    resources do
      federated_channel(:events, types: ["examples.system.deployment_lifecycle.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end

defmodule Jido.Cluster.Examples.DeploymentLifecycle.Cluster do
  @moduledoc "Owns the subscriber's journal and movement requests."
  use Jido.Cluster, otp_app: :jido_cluster
end

defmodule Jido.Cluster.Examples.DeploymentLifecycle.Independent do
  @moduledoc "Declares a subscriber on the independent worker allocation."
  use Jido.Topology, name: "11_01_independent", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, Jido.Cluster.Examples.DeploymentLifecycle.Recorder, labels: ["independent"]
    end

    resources do
      federated_channel(:events, types: ["examples.system.deployment_lifecycle.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end
