defmodule JidoCluster.Distributed.DockerExampleCleanupTest do
  use JidoCluster.Test.ClusterCase
  alias Jido.Cluster.HostProvider.Step
  alias JidoCluster.Examples.Support.DockerProviderCase
  alias JidoCluster.Test.{DockerAPI, DockerExampleNode, DockerExampleProvider}

  test "container absence covers only that worker's PIDs and unknown presence cannot pass cleanup", context do
    [control, worker] = context.cluster.nodes
    server = start_supervised!({DockerAPI, []})
    docker = [endpoint: DockerAPI.endpoint(server), engine_id: "cleanup-engine", container: %{"Image" => "prepared"}]

    assert {:ok, ledger} =
             cluster_call(context.cluster, control, DynamicSupervisor, :start_child, [
               JidoCluster.Test.Supervisor,
               {DockerExampleProvider, []}
             ])

    {:ok, step} =
      Step.new(%{namespace: "cleanup", scope: "default", host: Atom.to_string(worker), provider: "docker", id: "known"})

    engine = {200, %{"ID" => "cleanup-engine"}}

    observed = %{
      "Id" => String.duplicate("a", 64),
      "Created" => "2026-09-16T00:00:00Z",
      "State" => %{"Status" => "running"},
      "Config" => %{
        "Labels" => %{
          "io.jido.cluster.step" => Jason.encode!(Step.to_record(step)),
          "io.jido.cluster.incarnation" => "one"
        }
      }
    }

    DockerAPI.replies(server, [engine, {200, observed}])

    assert {:ok, resource} =
             cluster_call(context.cluster, control, DockerExampleProvider, :acquire, [
               step,
               [server: ledger, docker: docker]
             ])

    pid = cluster_call(context.cluster, worker, Process, :whereis, [JidoCluster.Test.Supervisor])
    assert is_pid(pid)
    stop_node(context.cluster, worker)
    entry = %{cluster: context.cluster, control: control, worker: worker, provider: ledger, docker: docker}
    cluster = Map.put(context.cluster, :transports, %{worker => {DockerExampleNode, entry}})
    c = %{cluster: cluster, control: control, docker: docker}
    DockerAPI.replies(server, [engine, {404, nil}])
    DockerProviderCase.stopped(c, worker, [pid])
    assert DockerAPI.remaining(server) == []

    DockerAPI.replies(server, [engine, {404, nil}])
    assert_raise ExUnit.AssertionError, fn -> DockerProviderCase.stopped(c, worker, [self()]) end
    DockerAPI.replies(server, [{503, nil}])
    assert_raise ExUnit.AssertionError, ~r/presence is unknown/, fn -> DockerProviderCase.stopped(c, worker, [pid]) end

    assert :ok =
             cluster_call(context.cluster, control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               ledger
             ])

    refute cluster_call(context.cluster, control, Process, :alive?, [ledger])
    DockerAPI.replies(server, [engine, {404, nil}])
    assert :ok = DockerProviderCase.if_present(c, resource, fn -> flunk("Absent worker must not be reconnected") end)
    DockerAPI.replies(server, [{503, nil}])

    assert_raise ExUnit.AssertionError, ~r/presence is unknown/, fn ->
      DockerProviderCase.if_present(c, resource, fn -> flunk("Unknown worker must not be reconnected") end)
    end

    assert DockerAPI.remaining(server) == []
    refute Enum.any?(DockerAPI.requests(server), &(&1.method == "DELETE"))
    stop_supervised!(DockerAPI)
    refute Process.alive?(server)
  end
end
