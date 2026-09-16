defmodule JidoCluster.JournalDefinitionTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.Journal.Definition
  alias Jido.Codec.Registry
  alias JidoCluster.Test.PlacementWorker, as: Worker
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  setup do
    base = RequirementScheduling.new!(id: "durable")
    schema = Zoi.object(%{tenant: Zoi.string()})
    {:ok, definition} = Jido.Topology.new(%{base.definition | schema: schema})
    {:ok, topology} = Jido.Topology.instantiate(definition, id: "durable", input: %{tenant: "north"})

    registry =
      Registry.new!(%{
        "schemas/workers/v1" => {:schema, schema},
        "agents/worker/v1" => {:agent, Worker},
        "atoms/node" => {:atom, :node},
        "atoms/tenant" => {:atom, :tenant}
      })

    %{topology: topology, registry: registry}
  end

  test "stable application IDs restore the definition and input from JSON", c do
    assert {:ok, document} = Definition.encode(c.topology, c.registry)
    assert document["definition"]["schema"] == "schemas/workers/v1"
    stored = document |> Jason.encode!() |> Jason.decode!()
    fresh_registry = Registry.new!(c.registry.entries)
    assert {:ok, restored} = Definition.decode(stored, fresh_registry)
    assert restored.definition == c.topology.definition
    assert restored.id == c.topology.id
    assert restored.input == %{tenant: "north"}
    assert restored.plan.agents == c.topology.plan.agents
  end

  test "unknown stored identifiers cannot construct an Agent module", c do
    {:ok, document} = Definition.encode(c.topology, c.registry)
    document = put_in(document, ["definition", "agents", Access.at(0), "module"], "untrusted/new-module")
    assert {:error, _} = Definition.decode(document, c.registry)
  end

  test "a temporary or incomplete registry is not silently derived", c do
    assert {:error, _} = Definition.encode(c.topology, %{})
    incomplete = Registry.new!(Map.delete(c.registry.entries, "atoms/tenant"))
    assert {:error, _} = Definition.encode(c.topology, incomplete)
  end

  test "runtime input is rejected before storage", c do
    for value <- [self(), make_ref(), fn -> :ok end] do
      assert {:error, _} = Definition.encode(%{c.topology | input: %{tenant: value}}, c.registry)
    end
  end

  test "malformed tagged input returns an error instead of raising", c do
    {:ok, document} = Definition.encode(c.topology, c.registry)

    for input <- [
          %{"type" => "binary", "bytes" => 12},
          %{"type" => "list", "items" => 1},
          %{"type" => "map", "entries" => [["same", 1], ["same", 2]]}
        ] do
      assert {:error, _} = Definition.decode(%{document | "input" => input}, c.registry)
    end
  end
end
