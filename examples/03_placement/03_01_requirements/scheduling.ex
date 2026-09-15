defmodule Jido.Cluster.Examples.RequirementScheduling do
  @moduledoc "Declares compute requirements without naming an Erlang node."
  use Jido.Topology, name: "placement_requirements", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Placement.Worker, labels: ["compute"]
    end
  end
end
