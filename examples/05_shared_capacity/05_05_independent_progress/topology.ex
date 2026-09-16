defmodule Jido.Cluster.Examples.IndependentProgress do
  @moduledoc "Keep separate capacity usable when a movement result is uncertain."
  use Jido.Topology, name: "05_05_independent_progress", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["moving"]
    end
  end
end

defmodule Jido.Cluster.Examples.IndependentProgress.Cluster do
  @moduledoc "Owns the example's connected capacity scope."
  use Jido.Cluster, otp_app: :jido_cluster
end

defmodule Jido.Cluster.Examples.IndependentProgress.Separate do
  @moduledoc "Requests a separate allocation while another drain remains uncertain."
  use Jido.Topology, name: "separate_allocation", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["independent"]
    end
  end
end
