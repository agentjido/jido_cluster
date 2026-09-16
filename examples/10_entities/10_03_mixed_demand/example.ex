defmodule Jido.Cluster.Examples.EntityMixedDemand do
  @moduledoc "Shares an exact worker slot with declared topology demand."
  alias Jido.Cluster.Entity
  alias Jido.Cluster.Examples.Entities.Device

  @doc "Returns the entity demand that shares the declared worker budget."
  @spec workload() :: {:ok, Entity.t()} | {:error, term()}
  def workload do
    Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Device, requirements: ["shared"])
  end
end

defmodule Jido.Cluster.Examples.EntityMixedDemand.Occupant do
  @moduledoc "Declares the non-entity occupant in the same Cluster scope."
  use Jido.Topology, name: "10_03_occupant", extensions: [Jido.Cluster.Topology.Extension]

  topology do
    agents do
      cluster_worker :worker, Jido.Cluster.Examples.Entities.Device, labels: ["shared"]
    end
  end
end
