defmodule JidoCluster.Test.Supervisor do
  @moduledoc false

  # Test-owned children must not require a manager supervisor in the package.
  # Each isolated peer gets this supervisor before fixture setup begins.
  def ensure_started do
    case DynamicSupervisor.start_link(strategy: :one_for_one, name: __MODULE__) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _}} ->
        :ok
    end
  end
end
