defmodule Jido.Cluster.Examples.BusLocality do
  @moduledoc "Core Topology for the 02 05 bus locality example."
  use Jido.Topology, name: "example_02_05_bus_locality"

  topology do
    agents do
      agent(:worker, Jido.Cluster.Examples.Topologies.Counter)
    end

    resources do
      bus(:events)
    end

    connections do
      subscribe(:worker, to: :events, path: "examples.cluster.topologies.increment")
    end
  end
end
