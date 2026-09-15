defmodule Jido.Cluster.Examples.UncertainHostLoss do
  @moduledoc "A disconnected source remains uncertain even when spare capacity exists."
  use Jido.Topology, name: "placement_host_loss", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker(:worker, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"])
    end
  end
end
