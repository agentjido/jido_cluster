defmodule JidoCluster.Examples.LastSlotTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.SharedCapacityCase
  alias Jido.Cluster.Examples.{LastSlot, SharedCapacity.Worker}

  @tag cluster_nodes: 3
  test "independent callers compete for one slot and only the winner starts", context do
    c = start(context, LastSlot, [{["compute"], 1}, {["compute"], 0}])
    parent = self()
    requests = Enum.zip(c.workers, ["first", "second"])

    tasks =
      for {caller, id} <- requests do
        token = api(c, :request_id)

        Task.async(fn ->
          send(parent, {:waiting, self()})

          receive do
            :go -> :ok
          after
            5_000 -> raise "caller barrier timed out"
          end

          result =
            cluster_call(c.cluster, caller, :erpc, :call, [
              c.control,
              Jido.Cluster,
              :deploy,
              [c.service, LastSlot.new!(id: id), [request_id: token]]
            ])

          {id, result}
        end)
      end

    callers =
      for _ <- tasks do
        assert_receive {:waiting, pid}
        pid
      end

    Enum.each(callers, &send(&1, :go))
    results = Task.await_many(tasks)
    assert [{winner, {:ok, operation}}] = Enum.filter(results, &match?({_, {:ok, _}}, &1))
    assert [{loser, {:error, {:no_capacity, "worker"}}}] = Enum.filter(results, &match?({_, {:error, _}}, &1))
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id])
    assert [%{topology_id: ^winner, state: :active}] = api(c, :claims)
    {:ok, ref} = api(c, :ref, [winner, :worker])
    assert {:ok, _} = api(c, :call, [ref, Worker.work_signal!()])
    {:ok, %{pid: pid}} = api(c, :lookup, [ref])
    count(c, pid, 1)
    assert {:error, :not_found} = api(c, :status, [loser])

    starts =
      for host <- c.workers do
        cluster_call(c.cluster, host, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)]).active
      end

    assert Enum.sum(starts) == 1
    cleanup(c)
  end
end
