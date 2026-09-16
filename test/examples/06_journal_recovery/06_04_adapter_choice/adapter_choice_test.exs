defmodule JidoCluster.Examples.JournalAdapterChoiceTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.JournalRecoveryCase
  alias Jido.Cluster.Examples.JournalAdapterChoice

  for backend <- [:bedrock, :mnesia] do
    @tag cluster_nodes: 2, tmp_dir: true, timeout: 90_000
    test "#{backend} preserves running state and stopped intent with separate Agent storage", context do
      c = start(context, JournalAdapterChoice, unquote(backend))
      deployed = deploy(c, JournalAdapterChoice.new!(id: "adapter"))
      work(c, deployed, 1)
      c = restart(c)
      recover(c)
      current = count(c, deployed.ref, 1)
      assert current != deployed.agent
      token = api(c, :request_id)
      {:ok, stop} = api(c, :stop, [deployed.topology.id, [request_id: token]])
      assert {:ok, %{phase: :completed}} = api(c, :await, [stop.id])
      refute cluster_call(c.cluster, node(current), Process, :alive?, [current])
      c = restart(c)
      assert {:ok, %{desired: :stopped, agent_readiness: :stopped}} = api(c, :status, [deployed.topology.id])
      assert {:ok, %{id: same}} = api(c, :stop, [deployed.topology.id, [request_id: token]])
      assert same == stop.id
      assert api(c, :claims) == []
      cleanup(c)
    end
  end

  test "missing default Repo configuration does not select memory mode", _context do
    assert {:error, {:invalid_journal, _}} = JournalAdapterChoice.Cluster.start_link([])
    refute Process.whereis(JournalAdapterChoice.Cluster)
    refute Process.whereis(JournalAdapterChoice.Cluster.Core)
  end
end
