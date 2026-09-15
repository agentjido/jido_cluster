defmodule Jido.Cluster.Examples.HostRecovery do
  @moduledoc "Core Topology for the 02 04 host recovery example."
  use Jido.Topology, name: "example_02_04_host_recovery"

  topology do
    agents do
      agent(:worker, Jido.Cluster.Examples.Topologies.Counter)
    end
  end
end
