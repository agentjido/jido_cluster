defmodule JidoCluster.Test.OperationBarrier do
  @moduledoc false

  def attach(observer, topology_id) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:jido, :cluster, :operation, :stop], &__MODULE__.hold/4, {observer, topology_id})
    id
  end

  def hold(_event, _measurements, %{action: :deploy, topology_id: id} = metadata, {observer, id}) do
    send(observer, {:operation_observed, self(), metadata})

    receive do
      :release -> :ok
    after
      10_000 -> raise "operation observation barrier timed out"
    end
  end

  def hold(_event, _measurements, _metadata, _config), do: :ok
end
