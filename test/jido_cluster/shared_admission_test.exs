defmodule JidoCluster.SharedAdmissionTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Topology.Controller
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "shared-admission"
  end

  setup context do
    hosts = [%{node: node(), labels: ["compute"], capacity: Map.get(context, :capacity, 1), available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})
    :ok
  end

  test "competing deployments cannot both acquire the last slot" do
    tokens = for _ <- 1..2, do: Cluster.request_id(Service)
    parent = self()

    tasks =
      for {token, id} <- Enum.zip(tokens, ["first", "second"]) do
        Task.async(fn ->
          send(parent, {:waiting, self()})

          receive do
            :go -> :ok
          after
            5_000 -> raise "reservation barrier timed out"
          end

          {id, Cluster.deploy(Service, RequirementScheduling.new!(id: id), request_id: token)}
        end)
      end

    waiters =
      for _ <- tasks do
        assert_receive {:waiting, pid}
        pid
      end

    Enum.each(waiters, &send(&1, :go))
    results = Task.await_many(tasks)
    assert [{winner, {:ok, op}}] = Enum.filter(results, &match?({_, {:ok, _}}, &1))
    assert [{loser, {:error, {:no_capacity, "worker"}}}] = Enum.filter(results, &match?({_, {:error, _}}, &1))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, op.id, 5_000)
    assert [%{topology_id: ^winner, state: :active}] = Cluster.claims(Service)
    {:ok, config} = Cluster.config(Service)
    assert Controller.whereis(config.jido, loser) == nil
    assert %{active: 1} = DynamicSupervisor.count_children(Jido.agent_supervisor_name(config.jido))
  end

  @tag capacity: 2
  test "confirmed stop releases only its own shared-host claims" do
    for id <- ["first", "second"] do
      {:ok, op} = Cluster.deploy(Service, RequirementScheduling.new!(id: id), request_id: Cluster.request_id(Service))
      assert {:ok, %{phase: :completed}} = Cluster.await(Service, op.id, 5_000)
    end

    {:ok, ref} = Cluster.ref(Service, "second", :worker)
    {:ok, %{pid: kept}} = Cluster.lookup(Service, ref)
    {:ok, stop} = Cluster.stop(Service, "first", request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id, 5_000)
    assert [%{topology_id: "second"}] = Cluster.claims(Service)
    assert Process.alive?(kept)
    assert {:ok, %{pid: ^kept}} = Cluster.lookup(Service, ref)
  end
end
