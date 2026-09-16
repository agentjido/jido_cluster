defmodule JidoCluster.Test.LabelTopology do
  @moduledoc "Core Topology for the 02 02 label extension example."
  use Jido.Topology, name: "example_02_02_label_extension", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, JidoCluster.Test.TopologyCounter, labels: ["compute"]
    end
  end
end
