defmodule JidoCluster.EntityMappingProbeTest do
  use ExUnit.Case, async: true
  alias Jido.Agent.Ref
  alias Jido.Cluster.Deployment.Planner
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  test "core owns entity Ref identity and preserves it across exact-node placement" do
    # This is a bounded design probe, not a second workload implementation.
    # Type-tagged deterministic bytes keep integer and binary domain keys distinct.
    ids =
      for key <- [1, "1", "device/a", {"site", "device"}] do
        "entity:v1:" <> Base.url_encode64(:erlang.term_to_binary({"devices", key}, [:deterministic]), padding: false)
      end

    assert length(Enum.uniq(ids)) == 4

    for id <- ids do
      instance = RequirementScheduling.new!(id: id)
      assert {:ok, placed} = Planner.instantiate(instance, %{"worker" => :entity_probe_host})
      original = Map.fetch!(instance.plan.agents, "agent/worker")
      moved = Map.fetch!(placed.plan.agents, "agent/worker")
      assert original.id == moved.id
      assert {:ok, ref} = Ref.new(namespace: "entities", id: original.id)
      assert {:ok, ^ref} = Ref.new(namespace: "entities", id: moved.id)
    end
  end

  test "current placement rejects dynamic group scope rather than adding another graph" do
    definition =
      Jido.Topology.new!(
        name: "entities",
        groups: [
          %{key: "devices", module: JidoCluster.Test.PlacementWorker, count: 2}
        ]
      )

    assert {:ok, topology} = Jido.Topology.instantiate(definition, id: "devices")
    assert {:error, :unsupported_topology} = Planner.plan(topology, [])
  end
end
