defmodule Jido.Cluster.Examples.EligibleNode do
  @moduledoc "Core Topology for the 02 01 eligible node example."
  use Jido.Topology, name: "example_02_01_eligible_node"

  topology do
    agents do
      agent(:control, Jido.Cluster.Examples.Topologies.Counter)
      agent(:worker, Jido.Cluster.Examples.Topologies.Counter)
    end
  end
end
