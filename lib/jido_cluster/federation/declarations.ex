defmodule Jido.Cluster.Federation.Declarations do
  @moduledoc """
  Pure, portable channel declarations for root singleton topologies.

  Each channel uses the exact `{namespace, topology_id, channel_key}` identity.
  A subscription names a root Agent declaration and resolves to its core Ref.
  It does not create a core local-Bus connection. No runtime resources start here.

  Version 1 permits eight channels, 32 exact types per channel, and 64 bindings.
  Channel keys are UTF-8 strings of 1–128 bytes. Types are dot-separated ASCII
  letters, digits, underscores, or hyphens, with a 255-byte bound; wildcards are
  not accepted. Each binding receives all allowed types of its channel. Required
  bindings default to true in the DSL. These count bounds do not replace the
  journal's aggregate byte bound.
  """

  alias Jido.Agent.{Authoring, Ref}
  alias Jido.Topology.{Instance, Plan}

  @metadata_key "jido.cluster.federation"
  @empty %{"version" => 1, "channels" => [], "bindings" => []}
  @type_pattern ~r/\A[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\z/

  @doc "Adds extension entities as versioned static metadata after validation."
  @spec lower(map(), [struct()], [struct()]) :: {:ok, map()} | {:error, Exception.t()}
  def lower(config, [], []) do
    with {:ok, _} <- read(config), do: {:ok, config}
  end

  def lower(config, channels, bindings) do
    if Map.has_key?(config.metadata, @metadata_key) do
      invalid(:duplicate_metadata)
    else
      document = %{
        "version" => 1,
        "channels" => Enum.map(channels, &%{"key" => key(&1.key), "types" => &1.types}),
        "bindings" =>
          Enum.map(bindings, &%{"agent" => key(&1.agent), "channel" => key(&1.to), "required" => &1.required})
      }

      updated = %{config | metadata: Map.put(config.metadata, @metadata_key, document)}
      with {:ok, _} <- read(updated), do: {:ok, updated}
    end
  end

  @doc "Validates declarations, including metadata supplied without the DSL."
  @spec read(map()) :: {:ok, map()} | {:error, Exception.t()}
  def read(%{metadata: metadata, agents: agents}) when is_map(metadata) and is_list(agents) do
    document = Map.get(metadata, @metadata_key, @empty)
    agent_keys = Enum.map(agents, &key(&1.key))
    validate(document, agent_keys)
  end

  def read(_), do: invalid(:invalid_definition)

  @doc "Resolves scoped channels and exact managed Refs without locating or starting Agents."
  @spec resolve(Instance.t(), String.t()) :: {:ok, [map()]} | {:error, Exception.t()}
  def resolve(%Instance{} = instance, namespace) do
    with true <- string?(namespace, 1024),
         {:ok, document} <- read(instance.definition) do
      Authoring.traverse(document["channels"], &resolve_channel(&1, document, instance, namespace))
    else
      false -> invalid(:invalid_namespace)
      error -> error
    end
  end

  defp validate(%{"version" => 1, "channels" => channels, "bindings" => bindings} = document, agents)
       when map_size(document) == 3 and is_list(channels) and is_list(bindings) do
    cond do
      not within_limits?(channels, bindings) -> invalid(:declaration_limit)
      not Enum.all?(channels, &channel?/1) -> invalid(:invalid_channel)
      not unique?(channels, & &1["key"]) -> invalid(:duplicate_channel)
      not Enum.all?(bindings, &binding?(&1, agents, channels)) -> invalid(:invalid_binding)
      not unique?(bindings, &{&1["agent"], &1["channel"]}) -> invalid(:duplicate_binding)
      true -> {:ok, document}
    end
  end

  defp validate(_, _), do: invalid(:invalid_document)

  defp within_limits?(channels, bindings), do: length(channels) <= 8 and length(bindings) <= 64

  defp channel?(%{"key" => key, "types" => types} = channel)
       when map_size(channel) == 2 and is_list(types) do
    string?(key, 128) and length(types) in 1..32 and Enum.all?(types, &type?/1) and unique?(types, & &1)
  end

  defp channel?(_), do: false

  defp binding?(%{"agent" => agent, "channel" => channel, "required" => required} = binding, agents, channels)
       when map_size(binding) == 3 and is_boolean(required) do
    is_binary(agent) and agent in agents and Enum.any?(channels, &(&1["key"] == channel))
  end

  defp binding?(_, _, _), do: false

  defp resolve_channel(channel, document, instance, namespace) do
    bindings = Enum.filter(document["bindings"], &(&1["channel"] == channel["key"]))

    with {:ok, resolved} <- Authoring.traverse(bindings, &resolve_binding(&1, instance, namespace)) do
      {:ok, %{scope: {namespace, instance.id, channel["key"]}, types: channel["types"], bindings: resolved}}
    end
  end

  defp resolve_binding(binding, instance, namespace) do
    plan_key = Plan.resolve(instance.plan, binding["agent"], :agent)

    with {:ok, spec} <- Map.fetch(instance.plan.agents, plan_key),
         {:ok, ref} <- Ref.new(namespace: namespace, id: spec.id) do
      {:ok, %{ref: ref, required: binding["required"]}}
    else
      _ -> invalid(:unresolved_agent)
    end
  end

  defp string?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
  defp type?(value), do: string?(value, 255) and Regex.match?(@type_pattern, value)
  defp unique?(values, key), do: length(values) == length(Enum.uniq_by(values, key))
  defp key(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp key(value), do: value
  defp invalid(reason), do: Authoring.error("Invalid federation declarations", %{reason: reason})
end
