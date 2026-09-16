defmodule JidoCluster.Examples.SharedDrainTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.SharedCapacityCase
  alias Jido.Cluster.Examples.{SharedCapacity.Worker, SharedDrain}
  alias JidoCluster.Test.MovementBarrier

  @tag cluster_nodes: 3
  test "a shared drain keeps committed counts and exclusion until explicit enable", context do
    c = start(context, SharedDrain, [{["compute"], 2}, {["compute"], 2}])
    [source, target] = c.workers

    refs =
      for count <- 1..2 do
        topology = selected_on(c, SharedDrain, "work-#{count}", source)
        {ref, previous} = deploy(c, topology)
        for _ <- 1..count, do: assert({:ok, _} = api(c, :call, [ref, Worker.work_signal!()]))
        {ref, previous, count}
      end

    assert {:ok, _} =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {MovementBarrier, []}
             ])

    {:ok, drain} = api(c, :drain, [source, [request_id: api(c, :request_id)]])
    eventually(fn -> cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status]) != [] end)
    assert length(api(c, :claims)) == 4

    assert {:error, {:resources_busy, [_, _]}} =
             api(c, :drain, [target, [request_id: api(c, :request_id)]])

    assert {:error, {:no_capacity, "worker"}} =
             api(c, :deploy, [SharedDrain.new!(id: "during-drain"), [request_id: api(c, :request_id)]])

    assert {:error, :drain_in_progress} = api(c, :enable_host, [source, [request_id: api(c, :request_id)]])
    # Release each bounded movement step only after its target is publicly ready.
    for _ <- 1..2 do
      eventually(fn -> cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :status]) != [] end)
      assert :ok = cluster_call(c.cluster, c.control, GenServer, :call, [MovementBarrier, :release])
    end

    assert {:ok, %{phase: :completed}} = api(c, :await, [drain.id])
    assert Enum.all?(api(c, :claims), &(&1.host == target and &1.state == :active))

    for {ref, previous, committed} <- refs do
      assert {:ok, %{pid: pid, node: ^target}} = api(c, :lookup, [ref])
      refute cluster_call(c.cluster, source, Process, :alive?, [previous])
      count(c, pid, committed)
    end

    topology = SharedDrain.new!(id: "after-drain")
    assert {:error, {:no_capacity, "worker"}} = api(c, :plan, [topology])
    assert {:ok, %{phase: :completed}} = api(c, :enable_host, [source, [request_id: api(c, :request_id)]])
    assert {:ok, %{placements: %{"worker" => ^source}}} = api(c, :plan, [topology])
    cleanup(c)
  end
end
