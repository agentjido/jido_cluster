defmodule JidoCluster.Test.CapacityTopology do
  @moduledoc "Two workers need two admitted slots before activation starts."
  use Jido.Topology, name: "placement_admission", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :first, JidoCluster.Test.PlacementWorker, labels: ["compute"]
      cluster_worker :second, JidoCluster.Test.PlacementWorker, labels: ["compute"]
    end
  end
end
