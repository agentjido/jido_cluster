defmodule Jido.Cluster.Examples.AttachedDeployment do
  @moduledoc "Deploys a core workload while the application retains core ownership."
  use Jido.Topology, name: "attached_deployment", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Deployment.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.AttachedDeployment.Cluster do
  @moduledoc "Attaches to the core name supplied in application or start configuration."
  use Jido.Cluster, otp_app: :jido_cluster
end
