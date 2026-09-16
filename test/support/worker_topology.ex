defmodule JidoCluster.Test.WorkerTopology do
  @moduledoc "Declares compute requirements without naming an Erlang node."
  use Jido.Topology, name: "placement_requirements", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, JidoCluster.Test.PlacementWorker, labels: ["compute"]
    end
  end
end
