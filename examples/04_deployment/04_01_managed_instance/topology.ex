defmodule Jido.Cluster.Examples.ManagedDeployment do
  @moduledoc "Deploys a core workload through a Cluster-owned core instance."
  use Jido.Topology, name: "managed_deployment", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Deployment.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.ManagedDeployment.Cluster do
  @moduledoc "Owns core when the application does not supply a jido option."
  use Jido.Cluster, otp_app: :jido_cluster
end
