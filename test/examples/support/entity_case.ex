defmodule JidoCluster.Examples.Support.EntityCase do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase

  alias Jido.Cluster
  alias Jido.Cluster.Entity
  alias Jido.Cluster.Examples.Entities.{Device, Scope}

  def start(context, inventories, opts \\ []) do
    [control | workers] = context.cluster.nodes
    assert length(workers) == length(inventories)
    namespace = "entity-example/#{System.unique_integer([:positive])}"
    table = shared_table(context.cluster, context.cluster.nodes)
    jido = Scope.Core
    persistence = {Jido.Persistence.Mnesia, table: table}

    for host <- context.cluster.nodes do
      assert {:ok, _} =
               cluster_call(context.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Jido, name: jido, namespace: namespace, persistence: persistence}
               ])
    end

    for host <- workers do
      assert {:ok, _} =
               cluster_call(context.cluster, host, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Cluster.HostRuntime, jido: jido}
               ])
    end

    hosts =
      Enum.zip_with(workers, inventories, fn worker, {labels, capacity} ->
        %{node: worker, labels: labels, capacity: capacity, available: true}
      end)

    c =
      Map.merge(context, %{
        control: control,
        workers: workers,
        jido: jido,
        namespace: namespace,
        table: table,
        persistence: persistence,
        hosts: hosts,
        service: Scope,
        instance: nil
      })

    if Keyword.get(opts, :start_instance, true), do: start_instance(c), else: c
  end

  def start_instance(c) do
    assert {:ok, instance} =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {c.service, jido: c.jido, journal: :memory, pools: [workers: [hosts: c.hosts]]}
             ])

    %{c | instance: instance}
  end

  def api(c, function, args \\ []),
    do: cluster_call(c.cluster, c.control, Cluster, function, [c.service | args])

  def entity(c, function, args),
    do: cluster_call(c.cluster, c.control, Entity, function, [c.service | args])

  def record(c, workload, identity, event_id) do
    assert {:ok, agent} = entity(c, :call, [workload, identity, Device.record_signal!(event_id)])
    agent
  end

  def snapshot(c, pid), do: cluster_call(c.cluster, node(pid), Jido.AgentServer, :snapshot, [pid])

  def selected_on(c, workload, host) do
    Enum.find_value(1..100, fn index ->
      identity = {"devices", "meter-#{index}"}
      {:ok, topology} = Entity.topology(workload, identity)

      case api(c, :plan, [topology]) do
        {:ok, %{placements: %{"entity" => ^host}}} -> identity
        _ -> nil
      end
    end) || raise "No device identity selected the requested source host"
  end

  def cleanup(c) do
    if c.instance do
      assert :ok =
               cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [
                 JidoCluster.Test.Supervisor,
                 c.instance
               ])
    end

    for worker <- c.workers do
      assert %{active: 0} =
               cluster_call(c.cluster, worker, DynamicSupervisor, :count_children, [
                 Jido.agent_supervisor_name(c.jido)
               ])
    end
  end
end
