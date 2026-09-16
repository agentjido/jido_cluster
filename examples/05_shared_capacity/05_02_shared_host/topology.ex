defmodule Jido.Cluster.Examples.SharedHost do
  @moduledoc "Stop one deployment without stopping another on the same host."
  use Jido.Topology, name: "05_02_shared_host", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.SharedHost.Cluster do
  @moduledoc "Owns the example's connected capacity scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
