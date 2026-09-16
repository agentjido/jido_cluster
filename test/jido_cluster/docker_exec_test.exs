defmodule JidoCluster.DockerExecTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster.HostProvider.{Resource, Step}
  alias JidoCluster.Test.{DockerAPI, DockerExec}
  alias JidoCluster.Test.DockerHost.RPC

  setup do
    server = start_supervised!({DockerAPI, []})
    output = start_supervised!({Agent, fn -> nil end})
    options = [endpoint: DockerAPI.endpoint(server), engine_id: "engine-1", container: %{"Image" => "prepared:test"}]

    {:ok, step} =
      Step.new(%{namespace: "exec", scope: "test", provider: "docker", host: "worker@127.0.0.1", id: "step"})

    {:ok, resource} = Resource.new(step, container_id(), "incarnation-1", :running)
    %{server: server, options: options, resource: resource, output: output}
  end

  test "exec uses an exact resource, hidden release RPC, framed output and confirmed process exit", c do
    DockerAPI.replies(c.server, replies(c))
    assert {:ok, :nonode@nohost} = DockerExec.call(c.resource, c.options, :erlang, :node, [], 1_000)
    assert DockerAPI.remaining(c.server) == []
    [_, _, create, start, inspect] = DockerAPI.requests(c.server)
    assert create.path == "/v1.47/containers/" <> container_id() <> "/exec"
    assert create.body["AttachStdin"] == false
    assert create.body["Tty"] == false
    assert ["timeout", "--signal=KILL", "6s", release, "rpc", expression] = create.body["Cmd"]
    assert release == "_build/prod/rel/jido_cluster_docker_host/bin/jido_cluster_docker_host"
    assert String.starts_with?(expression, "JidoCluster.Test.DockerHost.RPC.run(")
    assert start.path == "/v1.47/exec/" <> exec_id() <> "/start"
    assert start.body == %{"Detach" => false, "Tty" => false}
    assert inspect.path == "/v1.47/exec/" <> exec_id() <> "/json"
  end

  test "a changed Engine or resource cannot execute commands", c do
    for observations <- [
          [{200, %{"ID" => "changed"}}],
          [engine(), {404, nil}],
          [engine(), {200, record(%{c.resource | incarnation: "replacement"})}],
          [engine(), {200, record(%{c.resource | state: :stopped})}]
        ] do
      DockerAPI.replies(c.server, observations)
      assert {:error, :docker_rpc_unavailable} = DockerExec.call(c.resource, c.options, :erlang, :node, [])
      assert DockerAPI.remaining(c.server) == []
    end

    refute Enum.any?(DockerAPI.requests(c.server), &(&1.method == "POST"))
  end

  test "invalid streams, lost replies, and output limits cannot become successful calls", c do
    for stream <- [:close, {:stream, <<1, 0, 0, 0, 0, 0, 0, 9, "short">>}, {:stream, String.duplicate("x", 262_145)}] do
      DockerAPI.replies(c.server, Enum.take(replies(c), 3) ++ [stream])
      assert {:error, :docker_rpc_unavailable} = DockerExec.call(c.resource, c.options, :erlang, :node, [])
      assert DockerAPI.remaining(c.server) == []
    end

    assert Enum.count(DockerAPI.requests(c.server), &String.ends_with?(&1.path, "/exec")) == 3
  end

  test "an unconfirmed or mismatched exec process cannot establish worker evidence", c do
    for change <- [
          %{"Running" => true},
          %{"ExitCode" => 1},
          %{"ContainerID" => String.duplicate("f", 64)},
          %{"ID" => String.duplicate("e", 64)}
        ] do
      DockerAPI.replies(c.server, Enum.take(replies(c), 4) ++ [{200, Map.merge(finished(), change)}])
      assert {:error, :docker_rpc_unavailable} = DockerExec.call(c.resource, c.options, :erlang, :node, [])
      assert DockerAPI.remaining(c.server) == []
    end
  end

  defp replies(c) do
    create = fn request ->
      expression = List.last(request.body["Cmd"])

      [_, encoded] =
        Regex.run(
          ~r/\ARPC\.run\("([A-Za-z0-9+\/=]+)"\)\z/,
          String.replace_prefix(expression, "JidoCluster.Test.DockerHost.", "")
        )

      {:ok, id, result} = RPC.invoke(encoded)
      line = "JIDO_RPC:" <> id <> ":" <> Base.encode64(:erlang.term_to_binary({id, result})) <> "\n"
      Agent.update(c.output, fn _ -> line end)
      {201, %{"Id" => exec_id()}}
    end

    start = fn _ ->
      # The marker crosses two stdout frames and stderr must not reach results.
      <<first::binary-size(10), rest::binary>> = Agent.get(c.output, & &1)
      {:stream, frame(1, first) <> frame(2, "private stderr\n") <> frame(1, rest)}
    end

    [engine(), {200, record(c.resource)}, create, start, {200, finished()}]
  end

  defp frame(stream, value), do: <<stream, 0, 0, 0, byte_size(value)::unsigned-big-32, value::binary>>
  defp engine, do: {200, %{"ID" => "engine-1"}}
  defp container_id, do: String.duplicate("a", 64)
  defp exec_id, do: String.duplicate("b", 64)
  defp finished, do: %{"ID" => exec_id(), "ContainerID" => container_id(), "Running" => false, "ExitCode" => 0}

  defp record(resource) do
    %{
      "Id" => resource.id,
      "Created" => "2026-09-16T00:00:00Z",
      "State" => %{"Status" => if(resource.state == :running, do: "running", else: "exited")},
      "Config" => %{
        "Labels" => %{
          "io.jido.cluster.step" => Jason.encode!(Step.to_record(resource.step)),
          "io.jido.cluster.incarnation" => resource.incarnation
        }
      }
    }
  end
end
