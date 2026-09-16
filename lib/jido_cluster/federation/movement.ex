defmodule Jido.Cluster.Federation.Movement do
  @moduledoc false
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Deployment.Owner
  alias Jido.Cluster.Federation.Mirror
  alias Jido.Cluster.Instance.Service

  @doc "Confirms journaled source binding retirement before Core placement changes."
  @spec before_move(map(), map(), map()) :: :ok | {:error, term()}
  def before_move(state, current, desired) do
    guard = state.guard

    with {:ok, intent, transition} <-
           Service.call(
             guard.owner,
             {:federation_transition, state.instance.id, guard.activation, guard.binding_revision, current, desired}
           ),
         :ok <- retire(state, intent, transition) do
      prepare(state, intent, transition)
    end
  catch
    _, _ -> {:error, :binding_movement_uncertain}
  end

  defp retire(_, _, nil), do: :ok
  defp retire(_, _, %{"phase" => "retired"}), do: :ok

  defp retire(state, intent, transition) do
    metadata = %{
      namespace: state.guard.scope |> elem(0),
      topology_id: state.instance.id,
      activation_id: state.guard.activation.id,
      binding_revision: intent["revision"],
      phase: :retiring
    }

    :telemetry.span([:jido, :cluster, :federation, :retirement], metadata, fn ->
      result = retire_resources(state, intent, transition)

      outcome =
        case result do
          :ok -> %{phase: :retired, reason: nil}
          {:error, reason} -> %{phase: :uncertain, reason: reason}
        end

      {result, Map.merge(metadata, outcome)}
    end)
  end

  defp retire_resources(state, intent, transition) do
    with :ok <- each(transition["retire"], &change(state, :close, &1)),
         :ok <- each(transition["retire"], &stop(state, &1)),
         do:
           Service.call(
             state.guard.owner,
             {:federation_retired, state.instance.id, state.guard.activation, intent, transition}
           )
  end

  defp prepare(_, _, nil), do: :ok
  defp prepare(state, intent, _), do: each(intent["mirrors"], &change(state, :prepare, &1))

  defp change(state, action, resource) do
    with {:ok, host} <- host(state, resource["host"]),
         do: Owner.resource(state.owner, action, host, resource["channel"], resource["revision"])
  end

  defp stop(state, resource) do
    channel = resource["channel"]
    revision = resource["revision"]

    with {:ok, host} <- host(state, resource["host"]),
         {:ok, %{revision: ^revision} = record} <-
           Activation.resource_state(state.guard.activation, state.owner, host, channel) do
      stop_host(record.phase, state, host, channel, revision)
    else
      {:error, _} = error -> error
      _ -> {:error, :resource_revision_changed}
    end
  end

  defp stop_host(:settled, _, _, _, _), do: :ok

  defp stop_host(_, state, host, channel, revision) do
    if host in [node() | Node.list()],
      do:
        :erpc.call(
          host,
          Mirror,
          :stop_generation,
          [state.jido, state.guard.activation, state.owner, channel, revision],
          state.timeout
        ),
      else: {:error, :host_unreachable}
  end

  defp host(state, name) do
    case Enum.find([node() | Enum.map(state.hosts, & &1.node)], &(Atom.to_string(&1) == name)) do
      nil -> {:error, :unknown_binding_host}
      host -> {:ok, host}
    end
  end

  defp each(values, run),
    do:
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case run.(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
end
