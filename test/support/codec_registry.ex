defmodule JidoCluster.Test.CodecRegistry do
  @moduledoc false

  alias Jido.Codec.{Data, Registry}

  def for_agent(%Jido.Agent{} = agent) do
    {:ok, definition_entries} = Jido.Agent.Codec.Deriver.entries(agent)
    stable(definition_entries ++ Data.registry_entries(agent.state))
  end

  def for_topology(%Jido.Topology.Instance{} = instance) do
    {:ok, temporary} = Jido.Topology.Codec.Deriver.topology(instance.definition)

    member_entries =
      Enum.flat_map(instance.plan.agents, fn {_key, spec} ->
        definition = runtime_definition(instance, spec)
        {:ok, entries} = Jido.Agent.Codec.Deriver.entries(definition)
        agent = Jido.Agent.instantiate!(definition, id: spec.id, state: spec.initial_state)
        entries ++ Data.registry_entries(agent.state)
      end)

    temporary.entries
    |> Map.values()
    |> Kernel.++(member_entries)
    |> Kernel.++(Data.registry_entries(instance.input))
    |> stable()
  end

  def merge(registries) when is_list(registries) do
    registries
    |> Enum.flat_map(fn %Registry{entries: entries} -> Map.values(entries) end)
    |> stable()
  end

  def stable(entries) do
    entries
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {{kind, _value} = entry, index} ->
      {"test/#{kind}/#{index}", entry}
    end)
    |> Registry.new!()
  end

  defp runtime_definition(instance, spec) do
    source = Jido.Topology.Validation.agent_source(spec)
    {:ok, definition} = Jido.Topology.Validation.agent_definition(source)

    metadata =
      Map.put(definition.metadata, "jido.topology", %{id: instance.id, key: spec.key})

    definition = %{definition | metadata: metadata, vsn: nil}

    definition =
      if spec.subscriptions == [] do
        definition
      else
        subscriptions =
          Enum.map(spec.subscriptions, fn subscription ->
            [
              bus: Map.fetch!(instance.plan.resources, subscription.bus).id,
              path: subscription.path,
              retry_delay_ms: instance.definition.startup.retry_interval
            ]
          end)

        %{
          definition
          | plugins:
              definition.plugins ++
                [{Jido.Topology.BusInputs, subscriptions: subscriptions}]
        }
      end

    Jido.Agent.new!(definition)
  end
end
