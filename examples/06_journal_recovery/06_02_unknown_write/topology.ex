defmodule Jido.Cluster.Examples.UnknownJournalWrite do
  @moduledoc "Resolve a lost journal reply through the original request."
  use Jido.Topology, name: "06_02_unknown_write", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.JournalRecovery.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.UnknownJournalWrite.Cluster do
  @moduledoc "Owns the example's journaled deployment scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
