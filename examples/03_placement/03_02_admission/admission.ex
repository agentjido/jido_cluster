defmodule Jido.Cluster.Examples.CapacityAdmission do
  @moduledoc "Two workers need two admitted slots before activation starts."
  use Jido.Topology, name: "placement_admission", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :first, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
      cluster_worker :second, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
    end
  end
end
