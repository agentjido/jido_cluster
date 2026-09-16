defmodule Jido.Cluster.Examples.TransitionCapacity do
  @moduledoc "Reserve target slots before movement and retry after capacity is released."
  use Jido.Topology, name: "05_04_transition_capacity", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["movable"]
    end
  end
end

defmodule Jido.Cluster.Examples.TransitionCapacity.Cluster do
  @moduledoc "Owns the example's connected capacity scope."
  use Jido.Cluster, otp_app: :jido_cluster
end

defmodule Jido.Cluster.Examples.TransitionCapacity.Occupant do
  @moduledoc "Uses a target slot until the application explicitly stops it."
  use Jido.Topology, name: "transition_occupant", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.SharedCapacity.Worker, labels: ["target"]
    end
  end
end
