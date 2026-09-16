defmodule JidoCluster.Distributed.DockerRuntimeTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Test.DockerHost.{Recorder, Runtime}

  test "the prepared application registers its boot step and restores shared committed state", c do
    [control, worker] = c.cluster.nodes
    table = shared_table(c.cluster, [control])
    namespace = "docker-runtime/#{Jido.generate_id()}"

    {:ok, step} =
      Step.new(%{namespace: namespace, scope: "default", host: Atom.to_string(worker), provider: "test", id: "boot-1"})

    record = Step.to_record(step)

    env = %{
      "JIDO_CLUSTER_HOST_STEP" => Jason.encode!(record),
      "JIDO_CLUSTER_HOST_NODE" => Atom.to_string(worker),
      "JIDO_CLUSTER_CONTROL_NODE" => Atom.to_string(control),
      "JIDO_CLUSTER_TABLE" => Atom.to_string(table)
    }

    runtime = start(c, worker, env)
    guard = HostRuntime.name(Runtime.core())
    expected = [namespace: namespace, provider_step: record]

    assert {:ok, info} =
             cluster_call(c.cluster, worker, HostRuntime, :probe, [guard, expected])

    assert info.persistence_identity == {:adapter, Jido.Persistence.Mnesia}
    {:ok, ref} = cluster_call(c.cluster, worker, Jido, :agent_ref, [Runtime.core(), "recorder"])
    {:ok, previous} = cluster_call(c.cluster, worker, Jido, :start_agent_ref, [Runtime.core(), ref, Recorder])
    signal = Jido.Signal.new!(%{id: "committed", type: "docker.record", source: "/docker-runtime", data: %{}})
    assert {:ok, _} = cluster_call(c.cluster, worker, Jido, :call, [Runtime.core(), ref, signal])
    assert snapshot(c, worker, previous).agent.state.events == ["committed"]
    stop(c, worker, runtime)
    refute cluster_call(c.cluster, worker, Process, :alive?, [previous])
    runtime = start(c, worker, env)
    assert {:ok, current_info} = cluster_call(c.cluster, worker, HostRuntime, :probe, [guard, [provider_step: record]])
    refute current_info.incarnation == info.incarnation
    {:ok, current} = cluster_call(c.cluster, worker, Jido, :start_agent_ref, [Runtime.core(), ref, Recorder])
    assert current != previous
    assert snapshot(c, worker, current).agent.state.events == ["committed"]
    stop(c, worker, runtime)
    refute cluster_call(c.cluster, worker, Process, :alive?, [current])
    assert {:atomic, :ok} = cluster_call(c.cluster, control, :mnesia, :delete_table, [table])
  end

  test "borrowed boot can omit the stamp and malformed configuration starts no Core", c do
    [control, worker] = c.cluster.nodes

    env = %{
      "JIDO_CLUSTER_HOST_NODE" => Atom.to_string(worker),
      "JIDO_CLUSTER_CONTROL_NODE" => Atom.to_string(control),
      "JIDO_CLUSTER_NAMESPACE" => "borrowed-runtime"
    }

    invalid = Map.put(env, "JIDO_CLUSTER_HOST_STEP", "invalid")
    assert {:error, :invalid_docker_host_environment} = Runtime.config(invalid)
    oversized = Map.put(env, "JIDO_CLUSTER_CONTROL_NODE", String.duplicate("x", 256))
    assert {:error, :invalid_docker_host_environment} = Runtime.config(oversized)

    assert {:error, :docker_host_boot_failed} =
             cluster_call(c.cluster, worker, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {Runtime, invalid}
             ])

    assert nil == cluster_call(c.cluster, worker, Process, :whereis, [Runtime.core()])
    runtime = start(c, worker, env)

    assert {:ok, %{provider_step: nil}} =
             cluster_call(c.cluster, worker, HostRuntime, :probe, [
               HostRuntime.name(Runtime.core()),
               [namespace: "borrowed-runtime"]
             ])

    stop(c, worker, runtime)
  end

  test "an example Core exposes only its configured allocation and rejects invalid boot settings", c do
    [control, worker] = c.cluster.nodes
    core = Jido.Cluster.Examples.ProviderLifecycle.Cluster.Core

    env = %{
      "JIDO_CLUSTER_HOST_NODE" => Atom.to_string(worker),
      "JIDO_CLUSTER_CONTROL_NODE" => Atom.to_string(control),
      "JIDO_CLUSTER_NAMESPACE" => "provider-example-runtime",
      "JIDO_CLUSTER_CORE" => Atom.to_string(core),
      "JIDO_CLUSTER_ALLOCATION" => "shared",
      "JIDO_CLUSTER_CAPACITY" => "2"
    }

    invalid = [
      Map.put(env, "JIDO_CLUSTER_CORE", "Elixir.UnknownDockerCore"),
      Map.delete(env, "JIDO_CLUSTER_ALLOCATION"),
      Map.delete(env, "JIDO_CLUSTER_CAPACITY"),
      Map.put(env, "JIDO_CLUSTER_ALLOCATION", ""),
      Map.put(env, "JIDO_CLUSTER_ALLOCATION", String.duplicate("x", 129)),
      Map.put(env, "JIDO_CLUSTER_ALLOCATION", <<255>>)
    ]

    invalid =
      invalid ++
        Enum.map(["0", "-1", "257", "02", "+2", "2x", "2.0", " 2", ""], fn capacity ->
          Map.put(env, "JIDO_CLUSTER_CAPACITY", capacity)
        end)

    for settings <- invalid do
      assert {:error, :invalid_docker_host_environment} = Runtime.config(settings)

      assert {:error, :docker_host_boot_failed} =
               cluster_call(c.cluster, worker, DynamicSupervisor, :start_child, [
                 JidoCluster.Test.Supervisor,
                 {Runtime, settings}
               ])

      assert nil == cluster_call(c.cluster, worker, Process, :whereis, [core])
    end

    runtime = start(c, worker, env)
    assert is_pid(cluster_call(c.cluster, worker, Process, :whereis, [core]))
    assert nil == cluster_call(c.cluster, worker, Process, :whereis, [Runtime.core()])
    guard = HostRuntime.name(core)

    assert {:ok, _} =
             cluster_call(c.cluster, worker, HostRuntime, :probe, [guard, [namespace: env["JIDO_CLUSTER_NAMESPACE"]]])

    status = cluster_call(c.cluster, worker, HostRuntime, :status, [guard])
    assert Map.keys(status.allocations) == ["shared"]
    assert %{capacity: 2, claims: [], control: :unregistered} = status.allocations["shared"]
    stop(c, worker, runtime, core)
  end

  defp start(c, host, env) do
    {:ok, runtime} =
      cluster_call(c.cluster, host, DynamicSupervisor, :start_child, [JidoCluster.Test.Supervisor, {Runtime, env}])

    runtime
  end

  defp stop(c, host, runtime, core \\ Runtime.core()) do
    assert :ok =
             cluster_call(c.cluster, host, DynamicSupervisor, :terminate_child, [JidoCluster.Test.Supervisor, runtime])

    refute cluster_call(c.cluster, host, Process, :alive?, [runtime])
    assert nil == cluster_call(c.cluster, host, Process, :whereis, [core])
    assert nil == cluster_call(c.cluster, host, Process, :whereis, [HostRuntime.name(core)])
  end

  defp snapshot(c, host, pid), do: cluster_call(c.cluster, host, Jido.AgentServer, :snapshot, [pid])
end
