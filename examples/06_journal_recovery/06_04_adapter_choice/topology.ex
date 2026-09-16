defmodule Jido.Cluster.Examples.JournalAdapterChoice do
  @moduledoc "Select a journal adapter independently of Agent storage."
  use Jido.Topology, name: "06_04_adapter_choice", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.JournalRecovery.Worker, labels: ["compute"]
    end
  end
end

defmodule Jido.Cluster.Examples.JournalAdapterChoice.Cluster do
  @moduledoc "Owns the example's journaled deployment scope."
  use Jido.Cluster, otp_app: :jido_cluster
end
