defmodule JidoCluster.Test.Federation.SubscriberTopology do
  @moduledoc false
  use Jido.Topology, name: "federation_subscriber_fixture", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :listener, JidoCluster.Test.Federation.Subscriber, labels: ["compute"]
    end
  end
end
