defmodule Jido.Cluster.Instance.BindingRepair do
  @moduledoc false
  alias Jido.Cluster.Deployment
  alias Jido.Cluster.Federation.Runtime
  alias Jido.Cluster.Instance.{Hosts, Service}

  @doc "Checks and repairs bindings once without replacing accepted Agents or claims."
  @spec run(pid(), [String.t()]) :: :ok
  def run(owner, ids) do
    Enum.each(ids, &inspect_one(owner, &1))
    :ok
  end

  defp inspect_one(owner, id) do
    with {:ok, context} <- Service.call(owner, {:federation_context, id}),
         true <- needed?(context) do
      attempt(context, owner, id)
    end
  catch
    _, _ -> refused(owner, id, :binding_inspection_uncertain)
  end

  defp attempt(context, owner, id) do
    case Service.call(owner, {:binding_repair_prepare, id}) do
      {:ok, deployment} ->
        result = repair(context.config, owner, deployment)

        Service.call(
          owner,
          {:binding_repair_result, id, deployment.activation, deployment.federation["revision"], result}
        )

      {:error, reason} ->
        refused(owner, id, reason)
    end
  end

  defp refused(owner, id, reason) do
    Service.call(owner, {:binding_repair_refused, id, reason})
  catch
    :exit, _ -> :ok
  end

  defp needed?(%{deployment: d} = context) do
    Map.get(d, :federation_transition) != nil or
      case Runtime.status(context) do
        {:ok, %{binding_readiness: :ready, health: :healthy}} -> false
        _ -> true
      end
  end

  defp repair(config, owner, d) do
    guard =
      config
      |> Hosts.guard(owner, d.instance, d.selected)
      |> Map.merge(%{
        activation: d.activation,
        initial_selected: d.initial_selected,
        binding_revision: d.federation["revision"]
      })

    with :ok <- Deployment.repair_bindings(d.runner, d.selected, guard),
         do: await(d.runner, d.federation["revision"], System.monotonic_time(:millisecond) + config.timeout)
  catch
    _, _ -> {:error, :binding_repair_uncertain}
  end

  defp await(runner, revision, deadline) do
    case Deployment.status(runner).binding_repair do
      %{revision: ^revision, phase: :completed} -> :ok
      %{revision: ^revision, phase: :uncertain, reason: reason} -> {:error, reason}
      _ -> wait(runner, revision, deadline)
    end
  end

  defp wait(runner, revision, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :binding_repair_timeout}
    else
      receive do
      after
        10 -> await(runner, revision, deadline)
      end
    end
  end
end
