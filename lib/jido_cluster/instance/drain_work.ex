defmodule Jido.Cluster.Instance.DrainWork do
  @moduledoc false
  alias Jido.Cluster.{Deployment, Instance}
  alias Jido.Cluster.Instance.{Hosts, Service, Work}

  @doc "Moves reserved deployments in order and records each confirmed retirement."
  @spec run(Instance.Config.t(), pid(), String.t(), [map()]) :: map()
  def run(config, owner, parent, steps) do
    Enum.reduce_while(steps, %{phase: :completed, reason: nil}, fn step, _result ->
      case move(config, owner, parent, step) do
        :ok -> {:cont, %{phase: :completed, reason: nil}}
        {:error, reason} -> {:halt, %{phase: :uncertain, reason: reason}}
      end
    end)
  catch
    :exit, reason -> %{phase: :uncertain, reason: {:drain_interrupted, reason}}
  end

  defp move(config, owner, parent, step) do
    with {:ok, _} <- Hosts.confirm(config, step.instance, owner, step.arrivals, step.operation_id),
         guard = Hosts.guard(config, owner, step.instance, step.selected),
         {:ok, identity} <- Service.call(owner, {:federation_guard, step.id, parent, step.selected}),
         guard = Map.merge(guard, identity),
         :ok <- Deployment.apply_reservation(step.runner, step.selected, guard),
         %{phase: :completed} <- Work.wait_ready(step.runner, System.monotonic_time(:millisecond) + config.timeout),
         :ok <- observe_ready(config, parent, step),
         :ok <- Hosts.release(config, owner, retired_claims(owner, step)),
         :ok <- Service.call(owner, {:move_completed, parent, step}) do
      :ok
    else
      %{reason: reason} -> {:error, reason}
      error -> error
    end
  end

  defp observe_ready(config, parent, step) do
    :telemetry.execute([:jido, :cluster, :placement, :ready], %{system_time: System.system_time()}, %{
      namespace: config.namespace,
      scope: config.scope,
      topology_id: step.id,
      operation_id: step.operation_id,
      parent_operation_id: parent,
      phase: :target_ready,
      selected: step.selected,
      retiring: step.retired
    })
  end

  defp retired_claims(owner, step) do
    Service.call(owner, :claims)
    |> Enum.filter(&(&1.topology_id == step.id and Map.get(step.retired, &1.ref) == &1.host))
  end
end
