defmodule Jido.Cluster.Examples.PlacementRestart do
  @moduledoc "Restart adopts the core Controller's accepted worker placement."
  use Jido.Topology, name: "placement_restart", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
    end
  end
end
