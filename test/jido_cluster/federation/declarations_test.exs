defmodule JidoCluster.Federation.DeclarationsTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Ref
  alias Jido.Cluster.Deployment.Planner
  alias Jido.Cluster.Federation.Declarations
  alias Jido.Cluster.Journal.Definition
  alias Jido.Cluster.Topology.Extension
  alias JidoCluster.Test.CounterAgent

  defmodule Channels do
    use Jido.Topology, name: "federation_declaration_test", extensions: [Jido.Cluster.Topology.Extension]

    topology do
      agents do
        cluster_worker :worker, JidoCluster.Test.CounterAgent, labels: ["compute"]
      end

      resources do
        federated_channel(:events, types: ["counter.changed", "counter.reset"])
      end

      connections do
        federated_subscribe(:worker, to: :events)
      end
    end
  end

  test "authoring lowers portable declarations without local Bus resources or connections" do
    instance = Channels.new!(id: "one")
    assert instance.definition.resources == []
    assert instance.definition.connections == []
    assert instance.definition.metadata["jido.cluster.requirements"] == %{"worker" => ["compute"]}
    assert {:ok, document} = Declarations.read(instance.definition)
    assert document == document |> Jason.encode!() |> Jason.decode!()
    assert document["channels"] == [%{"key" => "events", "types" => ["counter.changed", "counter.reset"]}]
    assert document["bindings"] == [%{"agent" => "worker", "channel" => "events", "required" => true}]
    assert Enum.all?(instance.plan.agents, fn {_, spec} -> spec.subscriptions == [] end)
  end

  test "channel scope and subscriber Ref use the exact namespace and topology identity" do
    instance = Channels.new!(id: "one/two")
    assert {:ok, [channel]} = Declarations.resolve(instance, "north")
    assert channel.scope == {"north", "one/two", "events"}
    assert [%{ref: ref, required: true}] = channel.bindings
    assert ref == Ref.new!(namespace: "north", id: instance.plan.agents["agent/worker"].id)
    assert {:ok, [other_namespace]} = Declarations.resolve(instance, "south")
    assert {:ok, [other_topology]} = Declarations.resolve(Channels.new!(id: "two"), "north")
    refute other_namespace.scope == channel.scope
    refute other_namespace.bindings == channel.bindings
    refute other_topology.scope == channel.scope
    refute other_topology.bindings == channel.bindings
    assert {:error, _} = Declarations.resolve(instance, "")
  end

  test "journal definition round trip retains channel declarations and resolves the same Refs" do
    instance = Channels.new!(id: "stored")
    registry = %{"schema/v1" => {:schema, instance.definition.schema}, "counter/v1" => {:agent, CounterAgent}}
    assert {:ok, encoded} = Definition.encode(instance, registry)
    assert {:ok, restored} = Definition.decode(encoded |> Jason.encode!() |> Jason.decode!(), registry)
    assert Declarations.resolve(restored, "north") == Declarations.resolve(instance, "north")
  end

  test "invalid or duplicate channels, unsupported types, and unknown targets fail pure validation" do
    definition = Channels.new!(id: "invalid").definition
    valid = definition.metadata["jido.cluster.federation"]
    channel = hd(valid["channels"])
    binding = hd(valid["bindings"])

    invalid = [
      %{valid | "version" => 2},
      Map.put(valid, "unknown", true),
      %{valid | "channels" => [channel, channel]},
      %{valid | "channels" => [%{channel | "key" => ""}]},
      %{valid | "channels" => [%{channel | "types" => []}]},
      %{valid | "channels" => [%{channel | "types" => ["counter.*"]}]},
      %{valid | "channels" => [%{channel | "types" => ["counter.changed", "counter.changed"]}]},
      %{valid | "bindings" => [binding, binding]},
      %{valid | "bindings" => [%{binding | "agent" => "missing"}]},
      %{valid | "bindings" => [%{binding | "channel" => "missing"}]},
      %{valid | "bindings" => [%{binding | "required" => :yes}]},
      %{valid | "channels" => Enum.map(1..9, &%{channel | "key" => "channel-#{&1}"})}
    ]

    for document <- invalid do
      changed = %{definition | metadata: Map.put(definition.metadata, "jido.cluster.federation", document)}
      assert {:error, _} = Declarations.read(changed), inspect(document)
    end
  end

  test "extension rejects conflicting reserved metadata and keeps foreign entity order" do
    config = %{agents: [%{key: "worker", module: CounterAgent}], metadata: %{}}
    channel = struct(Extension.Channel, key: :events, types: ["counter.changed"])
    binding = struct(Extension.Subscription, agent: :worker, to: :events)
    foreign = [%URI{path: "one"}, %URI{path: "two"}]

    assert {:ok, lowered, ^foreign} =
             Extension.lower_topology(config, [hd(foreign), channel, binding, List.last(foreign)])

    assert {:error, _} = Extension.lower_topology(lowered, [channel])
    assert {:error, _} = Extension.lower_topology(config, [binding])
  end

  test "channel, exact type, and binding count limits reject the first excess declaration" do
    agents = for n <- 1..65, do: %{key: "agent-#{n}"}
    types = for n <- 1..32, do: "event.type_#{n}"
    channels = for n <- 1..8, do: %{"key" => "channel-#{n}", "types" => types}
    bindings = for n <- 1..64, do: %{"agent" => "agent-#{n}", "channel" => "channel-1", "required" => true}
    document = %{"version" => 1, "channels" => channels, "bindings" => bindings}
    read = fn value -> Declarations.read(%{agents: agents, metadata: %{"jido.cluster.federation" => value}}) end
    assert {:ok, ^document} = read.(document)
    assert {:error, _} = read.(%{document | "channels" => channels ++ [%{"key" => "ninth", "types" => types}]})
    assert {:error, _} = read.(%{document | "channels" => [%{hd(channels) | "types" => types ++ ["event.extra"]}]})

    assert {:error, _} =
             read.(%{
               document
               | "bindings" => bindings ++ [%{"agent" => "agent-65", "channel" => "channel-1", "required" => true}]
             })
  end

  test "static channel admission is pure and movement remains closed" do
    instance = Channels.new!(id: "static")
    hosts = [%{node: node(), labels: ["compute"], capacity: 1, available: true}]
    assert {:ok, selected} = Planner.plan(instance, hosts)
    assert :ok = Planner.static_federation(instance, selected, selected)

    assert {:error, :federation_movement_not_implemented} =
             Planner.static_federation(instance, %{"worker" => :other@host}, selected)
  end
end
