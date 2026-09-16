defmodule JidoCluster.DrainPlanTest do
  use ExUnit.Case, async: true
  alias Jido.Agent.Ref
  alias Jido.Cluster.{Admission, Drain}
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defp host(node, slots), do: %{node: node, capacity: slots, labels: ["compute"], available: true}

  defp setup_demand(target_slots) do
    {:ok, ledger} = Admission.new({"drain", "scope"}, [host(:source, 2), host(:target, target_slots)])

    Enum.reduce(["first", "second"], {ledger, %{}}, fn id, {ledger, deployments} ->
      instance = RequirementScheduling.new!(id: id)
      {:ok, ref} = Ref.new(namespace: "drain", id: instance.plan.agents["agent/worker"].id)
      {:ok, ledger} = Admission.reserve(ledger, id, %{ref => :source}, "deploy-#{id}")
      ledger = Admission.mark(ledger, "deploy-#{id}", :active)
      deployment = %{instance: instance, selected: %{"worker" => :source}, phase: :completed, desired: :running}
      {ledger, Map.put(deployments, id, deployment)}
    end)
  end

  test "all target capacity is reserved before any deployment moves" do
    {ledger, deployments} = setup_demand(2)
    assert {:ok, next, steps} = Drain.plan(ledger, deployments, :source, "drain")
    assert length(steps) == 2
    assert length(Admission.claims(next)) == 4
    assert Enum.all?(steps, &(&1.selected == %{"worker" => :target}))
    assert MapSet.member?(next.excluded, :source)
  end

  test "insufficient transition capacity rejects the complete drain" do
    {ledger, deployments} = setup_demand(1)
    assert {:error, {:no_capacity, "worker"}} = Drain.plan(ledger, deployments, :source, "drain")
    assert length(Admission.claims(ledger)) == 2
    refute MapSet.member?(ledger.excluded, :source)
  end

  test "an uncertain source is not a placement candidate or confirmed death" do
    {ledger, deployments} = setup_demand(2)
    ledger = Admission.uncertain_deployment(ledger, "first")
    assert {:error, {:resources_uncertain, _}} = Drain.plan(ledger, deployments, :source, "drain")
    assert length(Admission.claims(ledger)) == 2
  end

  test "a pending arrival prevents a target drain from reporting false completion" do
    {ledger, deployments} = setup_demand(2)
    {:ok, moving, _steps} = Drain.plan(ledger, deployments, :source, "first-drain")
    assert {:error, {:resources_busy, [_, _]}} = Drain.plan(moving, deployments, :target, "second-drain")
  end

  test "stopped intent does not hide claims whose cleanup is still pending" do
    {ledger, deployments} = setup_demand(2)
    stopping = Map.update!(deployments, "first", &%{&1 | phase: :accepted, desired: :stopped})
    assert {:error, {:resources_busy, [_]}} = Drain.plan(ledger, stopping, :source, "drain")
  end
end
