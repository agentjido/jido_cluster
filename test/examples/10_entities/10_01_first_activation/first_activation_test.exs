defmodule JidoCluster.Examples.EntityFirstActivationTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.EntityCase

  alias Jido.Cluster.Entity
  alias Jido.Cluster.Examples.{Entities.Device, EntityFirstActivation}

  @tag cluster_nodes: 3
  test "independent peers make first calls through one admitted entity activation", context do
    c = start(context, [{["shared"], 1}, {["shared"], 1}])
    {:ok, workload} = EntityFirstActivation.workload()
    identity = {"devices", "meter-1"}
    parent = self()

    tasks =
      for {caller, event_id} <- Enum.zip(c.workers, ["first-a", "first-b"]) do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              cluster_call(c.cluster, caller, :erpc, :call, [
                c.control,
                Entity,
                :call,
                [c.service, workload, identity, Device.record_signal!(event_id)]
              ])
          after
            5_000 -> {:error, :barrier_timeout}
          end
        end)
      end

    waiters =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(waiters, &send(&1, :go))
    assert Enum.all?(Task.await_many(tasks, 20_000), &match?({:ok, %Jido.Agent{}}, &1))
    assert {:ok, %{pid: pid, node: selected}} = entity(c, :lookup, [workload, identity])
    assert selected in c.workers
    assert %{agent: %{state: %{count: 2, last_event: last}}, state_version: 2} = snapshot(c, pid)
    assert last in ["first-a", "first-b"]

    assert {:ok, first} = entity(c, :ensure, [workload, identity])
    assert {:ok, second} = entity(c, :ensure, [workload, identity])
    assert first.operation.id == second.operation.id
    assert first.ref == second.ref
    assert first.status == :existing
    assert [%{ref: ref, host: ^selected, state: :active}] = api(c, :claims)
    assert ref == first.ref

    active =
      for worker <- c.workers do
        cluster_call(c.cluster, worker, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)]).active
      end

    assert Enum.sum(active) == 1
    cleanup(c)
  end
end
