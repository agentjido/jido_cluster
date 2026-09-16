defmodule Jido.Cluster.Instance.FederationMove do
  @moduledoc false
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Runtime, Transition}

  @doc "Adds complete binding retirement intent to a reserved drain before effects."
  @spec prepare(map(), [map()], String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(state, steps, operation) do
    Enum.reduce_while(steps, {:ok, state.deployments}, fn step, {:ok, deployments} ->
      d = Map.fetch!(deployments, step.id)

      case prepare_one(state.config, d, step.selected) do
        {:ok, d} -> {:cont, {:ok, Map.put(deployments, step.id, %{d | phase: :accepted, operation: operation})}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "Prepares or resumes mirror repair at the unchanged accepted placement."
  @spec repair(map(), map()) :: {:ok, map()} | {:error, term()}
  def repair(config, d) do
    selected = Map.new(d.selected, fn {key, host} -> {key, Atom.to_string(host)} end)

    case Map.get(d, :federation_transition) do
      nil ->
        prepare_one(config, d, d.selected)

      %{"from" => from} ->
        if from == selected,
          do: {:ok, d},
          else: {:error, :placement_transition_pending}
    end
  end

  defp prepare_one(_config, %{federation: nil} = d, _), do: {:ok, d}

  defp prepare_one(config, d, selected) do
    with {:ok, _} <- Runtime.plan(d.instance, config.namespace, selected, node(), config.federation),
         {:ok, {:active, owner}} <- Activation.inspect(d.activation),
         {:ok, resources} <- resources(d.activation, owner),
         {:ok, intent, transition} <- Transition.new(d, selected, resources),
         :ok <-
           Transition.validate(
             transition,
             Map.put(d, :federation, intent),
             d.selected,
             Enum.map(config.hosts, &Atom.to_string(&1.node)) ++ [d.activation.node]
           ) do
      {:ok, d |> Map.merge(%{selected: selected, federation: intent}) |> Map.put(:federation_transition, transition)}
    end
  catch
    :exit, _ -> {:error, :binding_control_unavailable}
  end

  defp resources(activation, owner) do
    with {:ok, keys} <- Activation.resources(activation, owner) do
      Enum.reduce_while(keys, {:ok, []}, &resource(&1, &2, activation, owner))
    end
  end

  defp resource({host, channel}, {:ok, acc}, activation, owner) do
    case Activation.resource_state(activation, owner, host, channel) do
      {:ok, %{revision: revision}} ->
        {:cont, {:ok, [%{"host" => Atom.to_string(host), "channel" => channel, "revision" => revision} | acc]}}

      error ->
        {:halt, error}
    end
  end
end
