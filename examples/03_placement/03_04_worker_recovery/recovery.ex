defmodule Jido.Cluster.Examples.WorkerRecovery do
  @moduledoc "The placement coordinator requests repair after worker exit."
  use Jido.Topology, name: "placement_worker_recovery", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
    end
  end
end
