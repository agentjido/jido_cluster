defmodule Jido.Cluster.Examples.NodeDrain do
  @moduledoc "A stateful worker can move away from a connected draining host."
  use Jido.Topology, name: "placement_drain", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
    end
  end
end
