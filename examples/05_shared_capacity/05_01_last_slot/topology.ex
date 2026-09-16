defmodule Jido.Cluster.Examples.LastSlot do
  @moduledoc "Share the final slot between independent deployment callers."
  use Jido.Topology, name: "05_01_last_slot", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.LastSlot.Cluster do
  @moduledoc "Owns the example's connected capacity scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
