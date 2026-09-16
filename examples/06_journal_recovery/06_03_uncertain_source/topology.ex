defmodule Jido.Cluster.Examples.UncertainJournalSource do
  @moduledoc "Retain uncertain source claims across service restart."
  use Jido.Topology, name: "06_03_uncertain_source", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.JournalRecovery.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.UncertainJournalSource.Cluster do
  @moduledoc "Owns the example's journaled deployment scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
