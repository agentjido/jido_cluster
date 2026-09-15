defmodule JidoCluster.SchedulerTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.Examples.RequirementScheduling
  alias Jido.Cluster.Scheduler
  alias Jido.Cluster.Scheduler.Operation
  alias Jido.Topology.Controller
  import JidoCluster.Test.Eventually

  setup do
    jido = :"scheduler_unit_#{System.unique_integer([:positive])}"
    start_supervised!({Jido, name: jido})
    opts = [jido: jido, topology: RequirementScheduling.new!(id: "scheduler"), hosts: [], poll_interval: 25]
    %{jido: jido, opts: opts}
  end

  test "invalid options and absent Jido instances are rejected", %{opts: opts} do
    for changes <- [[timeout: 0], [poll_interval: -1], [jido: false], [surprise: true]],
        do: assert({:error, :invalid_scheduler_options} = Scheduler.start_link(Keyword.merge(opts, changes)))

    assert {:error, :invalid_scheduler_options} = Scheduler.start_link(:bad)
    assert {:error, :jido_not_started} = Scheduler.start_link(Keyword.put(opts, :jido, :absent_scheduler_jido))
  end

  test "one scheduler owns the topology and rejected updates leave admission unchanged", %{opts: opts} do
    scheduler = start_supervised!({Scheduler, opts})
    eventually(fn -> Scheduler.status(scheduler).status == :blocked end)
    assert {:error, {:already_started, ^scheduler}} = Scheduler.start_link(opts)
    assert {:error, :invalid_inventory} = Scheduler.update_hosts(scheduler, [%{node: node()}])
    assert %{status: :blocked, reservations: %{}} = Scheduler.status(scheduler)
    assert :ok = Scheduler.stop(scheduler)
  end

  test "unconnected configured hosts do not start a Controller", %{opts: opts, jido: jido} do
    hosts = [%{node: :unconnected_scheduler_host, labels: ["compute"], capacity: 1, available: true}]
    scheduler = start_supervised!({Scheduler, Keyword.put(opts, :hosts, hosts)})
    eventually(fn -> Scheduler.status(scheduler).status == :blocked end)
    assert Controller.whereis(jido, "scheduler") == nil
    assert {:error, :unknown_host} = Scheduler.drain(scheduler, :unknown_host)
    assert :ok = Scheduler.stop(scheduler)
  end

  test "an existing core Controller cannot be taken over", %{opts: opts, jido: jido} do
    {:ok, controller} =
      DynamicSupervisor.start_child(
        Jido.Cluster.ManagerSupervisor,
        {Controller, jido: jido, topology: opts[:topology], repair: :manual}
      )

    on_exit(fn -> DynamicSupervisor.terminate_child(Jido.Cluster.ManagerSupervisor, controller) end)
    assert {:error, :controller_already_running} = Scheduler.start_link(opts)
    assert Process.alive?(controller)
    assert :ok = Operation.stop_controller(jido, "scheduler", 5_000)
  end

  test "a blocked coordinator releases its name on stop", %{opts: opts} do
    {:ok, scheduler} = Scheduler.start_link(opts)
    assert :ok = Scheduler.stop(scheduler)
    assert {:ok, next} = Scheduler.start_link(opts)
    assert :ok = Scheduler.stop(next)
  end

  test "supervisor shutdown cleans up a ready coordinator without a supervisor call cycle", %{opts: opts, jido: jido} do
    hosts = [%{node: node(), labels: ["compute"], capacity: 1, available: true}]
    scheduler = start_supervised!({Scheduler, Keyword.put(opts, :hosts, hosts)})
    eventually(fn -> Scheduler.status(scheduler).status == :ready end)
    worker = Scheduler.whereis_agent(scheduler, :worker)
    controller = Controller.whereis(jido, "scheduler")
    assert :ok = stop_supervised({Scheduler, "scheduler"})
    refute Process.alive?(scheduler)
    refute Process.alive?(controller)
    refute Process.alive?(worker)
    assert {:ok, next} = Scheduler.start_link(Keyword.put(opts, :hosts, hosts))
    assert :ok = Scheduler.stop(next)
  end
end
