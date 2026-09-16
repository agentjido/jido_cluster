defmodule JidoCluster.Examples.ManagedInstanceTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.DeploymentCase
  alias Jido.Cluster.Examples.{Deployment.Worker, ManagedDeployment}

  test "managed core starts before work and outlives confirmed remote cleanup", context do
    c = start_deployment(context, ManagedDeployment, :managed)
    core = cluster_call(c.cluster, c.control, Process, :whereis, [c.jido])
    assert {:ok, _} = api(c, :plan, [c.topology])
    assert nil == cluster_call(c.cluster, c.control, Jido.Topology.Controller, :whereis, [c.jido, "work"])
    {:ok, operation} = api(c, :deploy, [c.topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id, 5_000])
    {:ok, ref} = api(c, :ref, ["work", :worker])
    assert {:ok, %{state: %{count: 1}}} = api(c, :call, [ref, Worker.work_signal!()])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    assert node(agent) == c.worker

    # Service shutdown must settle the owned worker before stopping core.
    stop_instance(c)
    refute cluster_call(c.cluster, c.worker, Process, :alive?, [agent])
    refute cluster_call(c.cluster, c.control, Process, :alive?, [core])
  end
end
