defmodule Jido.Cluster.Examples.RequestIdentity do
  @moduledoc "Uses request identity independently of topology and Agent identity."
  use Jido.Topology, name: "request_identity", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Deployment.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.RequestIdentity.Cluster do
  @moduledoc "Keeps accepted request bindings for this explicit development instance."
  use Jido.Cluster, otp_app: :jido_cluster
end
