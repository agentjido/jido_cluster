defmodule Jido.Cluster.Examples.SharedDrain do
  @moduledoc "Drain all deployments from a shared host with stable Ref identity."
  use Jido.Topology, name: "05_03_shared_drain", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.SharedDrain.Cluster do
  @moduledoc "Owns the example's connected capacity scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
