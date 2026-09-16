defmodule Jido.Cluster.Examples.InterruptedDrain do
  @moduledoc "Resume a recorded drain after coordinator loss."
  use Jido.Topology, name: "06_01_interrupted_drain", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.JournalRecovery.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.InterruptedDrain.Cluster do
  @moduledoc "Owns the example's journaled deployment scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
