defmodule Jido.Cluster.Examples.StatefulMove do
  @moduledoc "Core Topology for the 02 03 stateful move example."
  use Jido.Topology, name: "example_02_03_stateful_move"

  topology do
    agents do
      agent(:worker, Jido.Cluster.Examples.Topologies.Counter)
    end
  end
end
