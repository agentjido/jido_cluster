defmodule JidoCluster.Test.Federation.DeclaredTopology do
  @moduledoc false
  use Jido.Topology, name: "declared_federation_fixture", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, JidoCluster.Test.Federation.Subscriber, labels: ["compute"]
    end

    resources do
      federated_channel(:events, types: ["counter.changed"])
    end

    connections do
      federated_subscribe(:listener, to: :events)
    end
  end
end
