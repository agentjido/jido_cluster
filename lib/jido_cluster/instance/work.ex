defmodule Jido.Cluster.Instance.Work do
  @moduledoc false
  alias Jido.Cluster.{Activation, Deployment, Instance}
  alias Jido.Cluster.Instance.Hosts

  @doc "Reports correlated operation boundaries outside the admission authority."
  @spec observe(map(), [map()], (-> map())) :: map()
  def observe(operation, claims, work) do
    metadata =
      operation
      |> Map.take([:attempt_id, :action, :topology_id, :namespace, :scope])
      |> Map.put(:operation_id, operation.id)
      |> Map.put(:claim_ids, Enum.map(claims, & &1.id))

    :telemetry.span([:jido, :cluster, :operation], metadata, fn ->
      result = work.()
      {result, Map.merge(metadata, Map.take(result, [:phase, :reason]))}
    end)
  end

  @doc "Confirms reserved host claims and waits for bounded deployment readiness."
  @spec deploy(Instance.Config.t(), map(), pid(), String.t() | nil) :: map()
  def deploy(config, deployment, owner, claim_operation \\ nil) do
    %{instance: topology, selected: selected, operation: operation, activation: activation} = deployment

    with {:ok, guard} <- confirm(config, deployment, owner, claim_operation || operation),
         guard = Map.put(guard, :initial_selected, Map.get(deployment, :initial_selected, selected)),
         guard = Map.put(guard, :binding_revision, get_in(deployment, [:federation, "revision"])),
         {:ok, runner} <- start_runner(config, topology, selected, Map.put(guard, :activation, activation)) do
      wait_ready(runner, System.monotonic_time(:millisecond) + config.timeout)
    else
      {:error, reason} -> %{phase: :uncertain, reason: reason, runner: nil}
    end
  end

  defp confirm(config, %{recovery: :pending, instance: topology}, owner, _operation),
    do: Hosts.confirm_retained(config, topology, owner)

  defp confirm(config, deployment, owner, operation),
    do: Hosts.confirm(config, deployment.instance, owner, deployment.selected, operation)

  defp start_runner(config, topology, selected, guard) do
    opts = [
      jido: config.jido,
      topology: topology,
      hosts: config.hosts,
      timeout: config.timeout,
      reservation: selected,
      federation: Map.from_struct(config.federation) |> Map.to_list(),
      guard: guard
    ]

    DynamicSupervisor.start_child(Instance.name(config.name, Deployments), {Deployment, opts})
  end

  @doc "Stops core first, then releases the exact host claims."
  @spec stop(Instance.Config.t(), map(), pid(), [map()]) :: map()
  def stop(config, deployment, owner, claims) do
    with :ok <- stop_runner(deployment),
         :ok <- Hosts.release(config, owner, claims) do
      %{phase: :completed, reason: nil, runner: nil}
    else
      {:error, reason} -> %{phase: :uncertain, reason: reason, runner: deployment.runner}
    end
  catch
    :exit, reason -> %{phase: :uncertain, reason: reason, runner: deployment.runner}
  end

  defp stop_runner(%{runner: nil, activation: activation}), do: Activation.cleanup(activation)
  defp stop_runner(%{runner: runner}), do: Deployment.stop(runner)

  @doc "Waits for the public placement result until a monotonic deadline."
  @spec wait_ready(pid(), integer()) :: map()
  def wait_ready(runner, deadline) do
    status = Deployment.status(runner)

    cond do
      status.status == :ready ->
        %{phase: :completed, reason: nil, runner: runner}

      status.status in [:blocked, :uncertain] ->
        %{phase: :uncertain, reason: status.error, runner: runner}

      System.monotonic_time(:millisecond) >= deadline ->
        %{phase: :uncertain, reason: :readiness_timeout, runner: runner}

      true ->
        # The bounded timer schedules a fresh public observation. It is not proof
        # of readiness: only the Controller-backed Deployment status supplies that.
        receive do
        after
          10 -> wait_ready(runner, deadline)
        end
    end
  catch
    :exit, reason -> %{phase: :uncertain, reason: reason, runner: runner}
  end
end
