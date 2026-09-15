defmodule Jido.Cluster.Examples.CoordinatorOwnership do
  @moduledoc "One connected coordinator owns worker repair and cleanup."
  use Jido.Topology, name: "placement_coordinator", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
    end
  end
end
