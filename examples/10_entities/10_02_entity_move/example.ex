defmodule Jido.Cluster.Examples.EntityMove do
  @moduledoc "Uses the same device mapping before and after a cooperative host drain."
  alias Jido.Cluster.Entity
  alias Jido.Cluster.Examples.Entities.Device

  @doc "Returns the device workload used before and after movement."
  @spec workload() :: {:ok, Entity.t()} | {:error, term()}
  def workload do
    Entity.new(definition_id: "devices/v1", keyspace: "devices", agent: Device, requirements: ["shared"])
  end
end
