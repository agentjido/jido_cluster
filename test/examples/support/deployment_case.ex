defmodule JidoCluster.Examples.Support.DeploymentCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase

  def start_deployment(c, topology, mode, extra \\ []) do
    [control, worker] = c.cluster.nodes
    service = Module.concat(topology, Cluster)
    jido = Module.concat(service, Core)
    namespace = "deployment/#{System.unique_integer([:positive])}"
    persistence = Keyword.get(extra, :agent_persistence)

    # Core and its host protocol run on each worker. Remote host preparation is
    # explicit: starting the control instance cannot start another BEAM node.
    cores = if mode == :attached, do: [control, worker], else: [worker]

    for host <- cores do
      assert {:ok, _} =
               cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace, persistence: persistence}
               ])
    end

    assert {:ok, _} =
             cluster_call(c.cluster, worker, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Jido.Cluster.HostRuntime, jido: jido}
             ])

    hosts = [%{node: worker, labels: ["compute"], capacity: 2, available: true}]
    opts = [namespace: namespace, journal: :memory, pools: [workers: [hosts: hosts]]]
    opts = if mode == :attached, do: Keyword.put(opts, :jido, jido), else: Keyword.merge(opts, extra)

    assert {:ok, instance} =
             cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {service, opts}
             ])

    Map.merge(c, %{
      control: control,
      worker: worker,
      service: service,
      jido: jido,
      instance: instance,
      namespace: namespace,
      topology: topology.new!(id: "work")
    })
  end

  def api(c, function, args \\ []),
    do: cluster_call(c.cluster, c.control, Jido.Cluster, function, [c.service | args])

  def stop_instance(c) do
    assert :ok =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               c.instance
             ])

    refute cluster_call(c.cluster, c.control, Process, :alive?, [c.instance])
  end
end
