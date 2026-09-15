defmodule JidoCluster.Placement.SelectionTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.Placement

  test "selection is stable across inventory order and excludes unavailable hosts" do
    hosts = [
      %{node: :b@local, labels: ["compute"], available: true},
      %{node: :a@local, labels: ["compute"], available: true},
      %{node: :c@local, labels: ["compute"], available: false}
    ]

    assert {:ok, selected} = Placement.select("worker", hosts, ["compute"])
    assert selected in [:a@local, :b@local]
    assert {:ok, ^selected} = Placement.select("worker", Enum.reverse(hosts), ["compute"])
  end

  test "no capacity and unsupported labels fail explicitly" do
    assert {:error, :no_eligible_node} = Placement.select("worker", [], [])

    assert {:error, :no_eligible_node} =
             Placement.select("worker", [%{node: :a@local, labels: ["general"], available: true}], ["compute"])
  end

  test "malformed and duplicate hosts cannot form an eligible view" do
    host = %{node: :a@local, labels: [], available: true}
    assert {:error, :invalid_inventory} = Placement.select("worker", [host, host], [])
    assert {:error, :invalid_inventory} = Placement.select("worker", [%{host | available: :unknown}], [])
    assert {:error, :invalid_requirements} = Placement.select("worker", [host], [""])
  end

  test "subscribed Agents must stay with their local Bus" do
    assert :ok = Placement.locality(%{subscriptions: []}, :a@local, :b@local)
    assert :ok = Placement.locality(%{subscriptions: [%{}]}, :a@local, :a@local)

    assert {:error, :local_bus_requires_controller_node} =
             Placement.locality(%{subscriptions: [%{}]}, :b@local, :a@local)
  end
end
