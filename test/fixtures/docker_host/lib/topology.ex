defmodule JidoCluster.Test.DockerHost.Topology do
  @moduledoc false
  use Jido.Topology, name: "docker_acceptance", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, JidoCluster.Test.DockerHost.Recorder, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["docker.record"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end
