defmodule JidoCluster.DockerProviderTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.HostProvider.{Docker, Resource, Step}
  alias JidoCluster.Test.DockerAPI

  setup do
    server = start_supervised!({DockerAPI, []})
    options = [endpoint: DockerAPI.endpoint(server), engine_id: "engine-1", container: %{"Image" => "prepared:test"}]

    {:ok, step} =
      Step.new(%{namespace: "docker", scope: "test", provider: "engine-1", host: "worker@127.0.0.1", id: "step-1"})

    %{server: server, options: options, step: step}
  end

  test "configuration is local, bounded, and keeps borrowed effects separate", c do
    assert :ok = Docker.validate_options(c.options)
    assert :ok = Docker.validate_options(endpoint: {:unix, "/tmp/docker.sock"}, engine_id: "one", borrowed_id: id())

    for options <- [
          Keyword.put(c.options, :endpoint, {:http, "http://remote:2375"}),
          Keyword.put(c.options, :timeout, :infinity),
          Keyword.put(c.options, :container, %{"Image" => "x", "HostConfig" => %{"AutoRemove" => true}}),
          Keyword.put(c.options, :container, %{"Image" => "x", "HostConfig" => %{AutoRemove: true}}),
          Keyword.put(c.options, :container, %{"Image" => "x", "Env" => ["JIDO_CLUSTER_HOST_STEP=wrong"]}),
          Keyword.put(c.options, :borrowed_id, id())
        ] do
      assert {:error, :invalid_docker_options} = Docker.validate_options(options)
    end

    assert DockerAPI.requests(c.server) == []
  end

  test "Unix socket requests check engine identity and authoritative absence", c do
    path = Path.join(System.tmp_dir!(), "jido-docker-#{Jido.generate_id()}.sock")
    server = start_supervised!({DockerAPI, %{path: path, replies: [engine(), absent()]}}, id: :unix_api)
    options = Keyword.put(c.options, :endpoint, DockerAPI.endpoint(server))
    assert {:ok, :absent} = Docker.inspect(c.step, options)
    assert DockerAPI.remaining(server) == []
    assert length(DockerAPI.requests(server)) == 2
    stop_supervised!(:unix_api)
    refute Process.alive?(server)
    refute File.exists?(path)
  end

  test "create injects the exact boot step and never retries a lost response", c do
    DockerAPI.replies(c.server, [engine(), absent(), :close])
    assert {:error, {:indeterminate, :docker_unavailable}} = Docker.acquire(c.step, c.options)
    [_, lookup, create] = DockerAPI.requests(c.server)
    assert create.method == "POST"
    assert create.path =~ "/containers/create?name=jido-cluster-"
    assert lookup.path == String.replace(create.path, "/create?name=", "/") <> "/json"
    assert Jason.decode!(create.body["Labels"]["io.jido.cluster.step"]) == Step.to_record(c.step)
    assert ("JIDO_CLUSTER_HOST_NODE=" <> c.step.host) in create.body["Env"]
    assert ("JIDO_CLUSTER_HOST_STEP=" <> Jason.encode!(Step.to_record(c.step))) in create.body["Env"]
    record = record(c.step, create.body["Labels"]["io.jido.cluster.incarnation"])
    DockerAPI.replies(c.server, [engine(), {200, record}])
    assert {:ok, resource} = Docker.inspect(c.step, c.options)
    assert resource.id == id()
    assert Enum.count(DockerAPI.requests(c.server), &(&1.method == "POST")) == 1
    assert DockerAPI.remaining(c.server) == []
  end

  test "successful create starts and inspects the immutable ID", c do
    # The final record has the same step and an observed incarnation. The adapter
    # gets that identity from inspection, not the create acknowledgement.
    DockerAPI.replies(c.server, [engine(), absent(), {201, %{"Id" => id()}}, {204, nil}, {200, record(c.step)}])
    assert {:ok, %{state: :running} = resource} = Docker.acquire(c.step, c.options)
    assert resource.id == id()
    requests = DockerAPI.requests(c.server)
    assert Enum.at(requests, 3).path == "/v1.47/containers/" <> id() <> "/start"
    assert List.last(requests).path == "/v1.47/containers/" <> id() <> "/json"
    assert DockerAPI.remaining(c.server) == []
  end

  test "engine change or unavailable inspection cannot report absence", c do
    DockerAPI.replies(c.server, [{200, %{"ID" => "another-engine"}}])
    assert {:error, :docker_engine_changed} = Docker.inspect(c.step, c.options)
    assert length(DockerAPI.requests(c.server)) == 1
    DockerAPI.replies(c.server, [engine(), {503, %{"message" => "credential must not escape"}}])
    assert {:error, :docker_inspection_unavailable} = Docker.inspect(c.step, c.options)
    DockerAPI.replies(c.server, [engine(), absent()])
    assert {:ok, :absent} = Docker.inspect(c.step, c.options)
  end

  test "stale incarnation prevents deletion and release uses only an exact ID", c do
    {:ok, resource} = Resource.new(c.step, id(), "incarnation-1", :running)
    DockerAPI.replies(c.server, [engine(), {200, record(c.step, "new-incarnation")}])
    assert {:error, {:rejected, :stale_resource}} = Docker.release(resource, c.options)
    refute Enum.any?(DockerAPI.requests(c.server), &(&1.method == "DELETE"))
    DockerAPI.replies(c.server, [engine(), {200, record(c.step)}, :close])
    assert {:error, {:indeterminate, :docker_delete_unconfirmed}} = Docker.release(resource, c.options)
    assert List.last(DockerAPI.requests(c.server)).path == "/v1.47/containers/" <> id() <> "?force=true&v=false"
    DockerAPI.replies(c.server, [engine(), absent()])
    assert {:ok, :absent} = Docker.inspect(c.step, c.options)
  end

  test "borrowed inspection accepts existing containers but forbids acquire and delete", c do
    options = c.options |> Keyword.delete(:container) |> Keyword.put(:borrowed_id, id())
    observed = put_in(record(c.step), ["Config", "Labels"], %{})
    DockerAPI.replies(c.server, [engine(), {200, observed}])
    assert {:ok, resource} = Docker.inspect(c.step, options)
    assert resource.incarnation == observed["Created"]
    assert {:error, {:rejected, :borrowed_resource}} = Docker.acquire(c.step, options)
    assert {:error, {:rejected, :docker_release_refused}} = Docker.release(resource, options)
    assert length(DockerAPI.requests(c.server)) == 2
  end

  test "large responses and a nonresponsive engine are bounded", c do
    DockerAPI.replies(c.server, [{200, String.duplicate("x", 262_145)}])
    assert {:error, :docker_response_limit} = Docker.inspect(c.step, c.options)
    DockerAPI.replies(c.server, [:hold])
    assert {:error, :docker_unavailable} = Docker.inspect(c.step, Keyword.put(c.options, :timeout, 50))
    assert length(DockerAPI.requests(c.server)) == 2
  end

  test "duplicate and conflicting creation inspect the existing step without another start", c do
    observed = record(c.step)
    DockerAPI.replies(c.server, [engine(), {200, observed}])
    assert {:ok, resource} = Docker.acquire(c.step, c.options)
    refute Enum.any?(DockerAPI.requests(c.server), &(&1.method == "POST"))
    DockerAPI.replies(c.server, [engine(), absent(), {409, %{}}, {200, observed}])
    assert {:ok, ^resource} = Docker.acquire(c.step, c.options)
    assert Enum.count(DockerAPI.requests(c.server), &(&1.method == "POST")) == 1
    refute Enum.any?(DockerAPI.requests(c.server), &String.ends_with?(&1.path, "/start"))
  end

  test "partial boot remains inspectable and deletion acceptance still needs inspection", c do
    DockerAPI.replies(c.server, [engine(), absent(), {201, %{"Id" => id()}}, {500, %{}}])
    assert {:error, {:indeterminate, :docker_start_unconfirmed}} = Docker.acquire(c.step, c.options)
    observed = put_in(record(c.step), ["State", "Status"], "created")
    DockerAPI.replies(c.server, [engine(), {200, observed}])
    assert {:ok, %{state: :starting} = resource} = Docker.inspect(c.step, c.options)
    DockerAPI.replies(c.server, [engine(), {200, observed}, {204, nil}])
    assert :ok = Docker.release(resource, c.options)
    DockerAPI.replies(c.server, [engine(), absent()])
    assert {:ok, :absent} = Docker.inspect(c.step, c.options)
  end

  test "malformed identities never authorize resource deletion", c do
    {:ok, resource} = Resource.new(c.step, id(), "incarnation-1", :running)

    invalid = [
      put_in(record(c.step), ["Config"], []),
      put_in(record(c.step), ["Config", "Labels", "io.jido.cluster.step"], 123),
      put_in(record(c.step), ["Id"], String.duplicate("b", 64)),
      record(%{c.step | id: "another-step"})
    ]

    for record <- invalid do
      DockerAPI.replies(c.server, [engine(), {200, record}])
      assert {:error, _} = Docker.release(resource, c.options)
    end

    refute Enum.any?(DockerAPI.requests(c.server), &(&1.method == "DELETE"))
  end

  test "discovery is bounded and verifies each exact candidate in the requested scope", c do
    observed = record(c.step)
    summary = %{"Id" => id(), "Labels" => observed["Config"]["Labels"]}
    DockerAPI.replies(c.server, [engine(), {200, [summary]}, {200, observed}])
    assert {:ok, [resource]} = Docker.discover({c.step.namespace, c.step.scope}, 1, c.options)
    assert resource.id == id()
    list = Enum.at(DockerAPI.requests(c.server), 1)
    query = URI.parse(list.path).query |> URI.decode_query()
    assert query["limit"] == "2"
    assert query["all"] == "true"

    assert Jason.decode!(query["filters"])["label"] == [
             "io.jido.cluster.namespace=docker",
             "io.jido.cluster.scope=test"
           ]

    DockerAPI.replies(c.server, [engine(), {200, [summary, summary]}])
    assert {:error, :discovery_limit} = Docker.discover({c.step.namespace, c.step.scope}, 1, c.options)
    DockerAPI.replies(c.server, [engine(), {200, [summary]}])
    assert {:error, :docker_discovery_unconfirmed} = Docker.discover({"another", c.step.scope}, 1, c.options)
    assert {:error, :invalid_discovery_limit} = Docker.discover({c.step.namespace, c.step.scope}, 0, c.options)
  end

  defp engine, do: {200, %{"ID" => "engine-1"}}
  defp absent, do: {404, %{"message" => "No such container"}}
  defp id, do: String.duplicate("a", 64)

  defp record(step, incarnation \\ "incarnation-1") do
    %{
      "Id" => id(),
      "Created" => "2026-09-16T00:00:00Z",
      "State" => %{"Status" => "running"},
      "Config" => %{
        "Labels" => %{
          "io.jido.cluster.step" => Jason.encode!(Step.to_record(step)),
          "io.jido.cluster.incarnation" => incarnation
        }
      }
    }
  end
end
