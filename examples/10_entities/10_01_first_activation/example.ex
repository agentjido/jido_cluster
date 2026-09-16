defmodule Jido.Cluster.Examples.EntityFirstActivation do
  @moduledoc "Declares a versioned device workload for on-demand admission."
  alias Jido.Cluster.Entity
  alias Jido.Cluster.Examples.Entities.Device

  @doc "Returns the shared device workload for concurrent first calls."
  @spec workload() :: {:ok, Entity.t()} | {:error, term()}
  def workload do
    Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Device, requirements: ["shared"])
  end
end
