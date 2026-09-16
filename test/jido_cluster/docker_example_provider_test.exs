defmodule JidoCluster.DockerExampleProviderTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.HostProvider.Step
  alias JidoCluster.Test.{DockerAPI, DockerExampleProvider}

  test "lost acquisition and failed inspection retain one real adapter step without another create" do
    server = start_supervised!({DockerAPI, []})
    ledger = start_supervised!({DockerExampleProvider, []})
    id = String.duplicate("a", 64)

    {:ok, step} =
      Step.new(%{namespace: "example", scope: "default", host: "worker@127.0.0.1", provider: "docker", id: "one"})

    docker = [endpoint: DockerAPI.endpoint(server), engine_id: "engine", container: %{"Image" => "prepared"}]
    options = [server: ledger, docker: docker]

    observed = %{
      "Id" => id,
      "Created" => "2026-09-16T00:00:00Z",
      "State" => %{"Status" => "running"},
      "Config" => %{
        "Labels" => %{
          "io.jido.cluster.step" => Jason.encode!(Step.to_record(step)),
          "io.jido.cluster.incarnation" => "incarnation"
        }
      }
    }

    engine = {200, %{"ID" => "engine"}}
    DockerAPI.replies(server, [engine, {404, nil}, {201, %{"Id" => id}}, {204, nil}, {200, observed}])
    assert :ok = DockerExampleProvider.mode(ledger, :lose_acquire_reply)
    assert {:error, {:indeterminate, :withheld_acquire_reply}} = DockerExampleProvider.acquire(step, options)
    assert [step] == DockerExampleProvider.steps(ledger)
    assert DockerAPI.remaining(server) == []
    before = DockerAPI.requests(server)
    assert :ok = DockerExampleProvider.mode(ledger, :inspect_unavailable)
    assert {:error, :unavailable} = DockerExampleProvider.inspect(step, options)
    assert before == DockerAPI.requests(server)
    DockerAPI.replies(server, [engine, {200, observed}])
    assert {:ok, resource} = DockerExampleProvider.inspect(step, options)
    assert resource.id == id
    assert resource.step == step
    assert [{:acquire, ^step}, {:inspect, ^step}, {:inspect, ^step}] = DockerExampleProvider.calls(ledger)
    assert Enum.count(DockerAPI.requests(server), &String.contains?(&1.path, "/containers/create")) == 1
    DockerAPI.replies(server, [engine, {200, observed}, {204, nil}])
    assert :ok = DockerExampleProvider.release(resource, options)
    assert List.last(DockerExampleProvider.calls(ledger)) == {:release, resource}
    assert List.last(DockerAPI.requests(server)).path == "/v1.47/containers/" <> id <> "?force=true&v=false"
    assert DockerAPI.remaining(server) == []
    stop_supervised!(DockerExampleProvider)
    stop_supervised!(DockerAPI)
    refute Process.alive?(ledger)
    refute Process.alive?(server)
  end
end
