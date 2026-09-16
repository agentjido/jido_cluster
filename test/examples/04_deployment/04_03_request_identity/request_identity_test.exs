defmodule JidoCluster.Examples.RequestIdentityTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.DeploymentCase
  alias Jido.Cluster.Examples.RequestIdentity
  alias JidoCluster.Examples.Support.StartBarrier

  test "duplicate requests share one operation while activation is held", context do
    [_, worker] = context.cluster.nodes
    table = shared_table(context.cluster, context.cluster.nodes)

    assert {:ok, _} =
             cluster_call(context.cluster, worker, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {StartBarrier, []}
             ])

    c =
      start_deployment(context, RequestIdentity, :managed, agent_persistence: {StartBarrier.Persistence, table: table})

    token = api(c, :request_id)
    {:ok, accepted} = api(c, :deploy, [c.topology, [request_id: token]])
    eventually(fn -> cluster_call(c.cluster, worker, GenServer, :call, [StartBarrier, :status]).waiting == 1 end)
    assert {:error, :timeout} = api(c, :await, [accepted.id, 0])

    # These independent peer channels submit the same request to the authority.
    replies =
      for caller <- c.cluster.nodes do
        Task.async(fn ->
          cluster_call(c.cluster, caller, :erpc, :call, [
            c.control,
            Jido.Cluster,
            :deploy,
            [c.service, c.topology, [request_id: token]]
          ])
        end)
      end
      |> Task.await_many(5_000)

    assert Enum.all?(replies, fn {:ok, op} -> op.id == accepted.id and op.phase == :accepted end)
    assert {:error, :request_conflict} = api(c, :deploy, [RequestIdentity.new!(id: "other"), [request_id: token]])
    assert %{arrivals: 1, waiting: 1} = cluster_call(c.cluster, worker, GenServer, :call, [StartBarrier, :status])
    assert :ok = cluster_call(c.cluster, worker, GenServer, :call, [StartBarrier, :release])
    assert {:ok, %{phase: :completed}} = api(c, :await, [accepted.id, 5_000])

    assert %{active: 1} =
             cluster_call(c.cluster, worker, DynamicSupervisor, :count_children, [Jido.agent_supervisor_name(c.jido)])

    {:ok, ref} = api(c, :ref, ["work", :worker])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    stop_instance(c)
    refute cluster_call(c.cluster, worker, Process, :alive?, [agent])
  end
end
