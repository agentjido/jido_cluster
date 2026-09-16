defmodule JidoCluster.Examples.AttachedInstanceTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  import JidoCluster.Examples.Support.DeploymentCase
  alias Jido.Cluster.Examples.{AttachedDeployment, Deployment.Worker}

  test "attached service stops its deployment and retains application core", context do
    c = start_deployment(context, AttachedDeployment, :attached)
    core = cluster_call(c.cluster, c.control, Process, :whereis, [c.jido])
    {:ok, operation} = api(c, :deploy, [c.topology, [request_id: api(c, :request_id)]])
    assert {:ok, %{phase: :completed}} = api(c, :await, [operation.id, 5_000])
    {:ok, ref} = api(c, :ref, ["work", :worker])
    assert {:ok, %{state: %{count: 1}}} = api(c, :call, [ref, Worker.work_signal!()])
    {:ok, %{pid: agent}} = api(c, :lookup, [ref])
    stop_instance(c)
    refute cluster_call(c.cluster, c.worker, Process, :alive?, [agent])
    assert cluster_call(c.cluster, c.control, Process, :alive?, [core])
    assert c.namespace == cluster_call(c.cluster, c.control, Jido, :namespace, [c.jido])
  end
end
