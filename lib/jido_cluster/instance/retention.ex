defmodule Jido.Cluster.Instance.Retention do
  @moduledoc false
  alias Jido.Cluster.Journal

  @doc "Reports retained bindings and unresolved operations for the current epoch."
  @spec status(map()) :: map()
  def status(state),
    do: %{
      epoch: state.epoch,
      generation: state.generation,
      requests: map_size(state.requests),
      unresolved_operations: unresolved(state)
    }

  @doc "Checks record-count capacity before accepting a new request."
  @spec admit(map(), :accepted | :completed) :: :ok | {:error, atom()}
  def admit(state, phase) do
    cond do
      map_size(state.requests) >= Journal.limits().request_bindings -> {:error, :retention_saturated}
      phase == :accepted and unresolved(state) >= Journal.limits().unresolved_operations -> {:error, :operation_limit}
      true -> :ok
    end
  end

  @doc "Advances a full completed epoch without removing deployments or claims."
  @spec rotate(map()) :: {:ok, map()} | {:error, :retention_saturated}
  def rotate(state) do
    cond do
      map_size(state.requests) < Journal.limits().request_bindings ->
        {:ok, state}

      unresolved(state) != 0 ->
        {:error, :retention_saturated}

      true ->
        {:ok,
         %{state | epoch: state.epoch + 1, requests: %{}, operations: %{}, ledger: compact_reservations(state.ledger)}}
    end
  end

  @doc "Bounds stored deployments, including stopped intent."
  @spec deployment(map(), String.t()) :: :ok | {:error, :deployment_limit}
  def deployment(state, id) do
    if Map.has_key?(state.deployments, id) or map_size(state.deployments) < Journal.limits().deployments,
      do: :ok,
      else: {:error, :deployment_limit}
  end

  @doc "Bounds all retained claims, including movement source and target claims."
  @spec claims(Jido.Cluster.Admission.t()) :: :ok | {:error, :claim_limit}
  def claims(ledger),
    do: if(map_size(ledger.claims) <= Journal.limits().claims, do: :ok, else: {:error, :claim_limit})

  defp unresolved(state),
    do: Enum.count(state.operations, fn {_, op} -> op.phase not in [:completed, :failed] end)

  defp compact_reservations(ledger) do
    requests =
      ledger.claims
      |> Map.values()
      |> Enum.group_by(& &1.operation_id)
      |> Map.new(fn {id, [first | _] = claims} ->
        {id, {first.topology_id, Map.new(claims, &{&1.ref, &1.host})}}
      end)

    %{ledger | requests: requests}
  end
end
