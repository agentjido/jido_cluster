defmodule JidoCluster.Placement.PlannerTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.Examples.CapacityAdmission
  alias Jido.Cluster.Scheduler.Planner

  defp host(worker, capacity), do: %{node: worker, labels: ["compute"], available: true, capacity: capacity}

  test "admission is complete and preserves eligible existing placements" do
    instance = CapacityAdmission.new!(id: "planner")
    assert {:ok, placements} = Planner.plan(instance, [host(:a, 1), host(:b, 1)])
    assert placements |> Map.values() |> Enum.sort() == [:a, :b]
    assert {:ok, ^placements} = Planner.plan(instance, [host(:a, 1), host(:b, 1), host(:c, 2)], [], placements)
  end

  test "an exhausted inventory returns no partial admission" do
    instance = CapacityAdmission.new!(id: "planner")
    assert {:error, {:no_capacity, "second"}} = Planner.plan(instance, [host(:a, 1)])
  end

  test "invalid and duplicate host capacities fail before planning" do
    instance = CapacityAdmission.new!(id: "planner")

    for hosts <- [[host(:a, -1)], [host(:a, 1), host(:a, 2)], [%{node: :a}]],
        do: assert({:error, :invalid_inventory} = Planner.plan(instance, hosts))
  end

  test "drain excludes a host and keeps other admitted placements stable" do
    instance = CapacityAdmission.new!(id: "planner")
    current = %{"first" => :a, "second" => :b}

    assert {:ok, %{"first" => :c, "second" => :b}} =
             Planner.plan(instance, [host(:a, 1), host(:b, 1), host(:c, 1)], [:a], current)
  end

  test "unsupported group definitions are rejected rather than partly admitted" do
    definition =
      Jido.Topology.new!(
        name: "groups",
        groups: [%{key: "workers", module: Jido.Cluster.Examples.Placement.Worker, count: 2}]
      )

    instance = Jido.Topology.unwrap!(Jido.Topology.instantiate(definition, id: "groups"))
    assert {:error, :unsupported_topology} = Planner.plan(instance, [host(:a, 2)])
  end

  test "unknown or invalid requirements cannot be silently ignored" do
    source = CapacityAdmission.topology()

    for requirements <- [%{"missing" => ["compute"]}, %{"first" => [""]}, "bad"] do
      definition = %{source | metadata: %{"jido.cluster.requirements" => requirements}}
      instance = Jido.Topology.unwrap!(Jido.Topology.instantiate(definition, id: "requirements"))
      assert {:error, :invalid_requirements} = Planner.plan(instance, [host(:a, 2)])
    end
  end

  test "a packed swap is rejected before arrivals can exceed a target budget" do
    source = CapacityAdmission.topology()
    definition = %{source | metadata: %{"jido.cluster.requirements" => %{"first" => ["a"], "second" => ["b"]}}}
    instance = Jido.Topology.unwrap!(Jido.Topology.instantiate(definition, id: "swap"))
    hosts = [%{host(:a, 1) | labels: ["a"]}, %{host(:b, 1) | labels: ["b"]}]
    assert {:error, {:transition_capacity, :a}} = Planner.plan(instance, hosts, [], %{"first" => :b, "second" => :a})
  end
end
