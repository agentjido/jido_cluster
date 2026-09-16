defmodule JidoCluster.Test.DockerExec do
  @moduledoc false
  alias Jido.Cluster.HostProvider.{Docker, Resource}
  alias Jido.Cluster.HostProvider.Docker.{HTTP, Options}
  alias JidoCluster.Test.DockerHost.RPC
  @release "_build/prod/rel/jido_cluster_docker_host/bin/jido_cluster_docker_host"
  @limit 262_144

  def call(resource, options, module, function, args, timeout \\ 15_000) do
    with {:ok, id, encoded} <- RPC.request(module, function, args, timeout),
         {:ok, config} <- Options.new(options),
         {:ok, %Resource{state: :running} = current} <- Docker.inspect(resource.step, options),
         true <- Resource.same?(resource, current),
         {:ok, exec} <- create(config, resource.id, encoded, timeout),
         {:ok, stdout} <- start(config, exec, timeout),
         :ok <- finished(config, exec, resource.id),
         result <- RPC.response(id, stdout) do
      result
    else
      _ -> {:error, :docker_rpc_unavailable}
    end
  end

  defp create(config, container, encoded, timeout) do
    # Both arguments contain only a fixed expression and generated Base64. The
    # Engine receives an argv array; no shell parses request terms or cookies.
    expression = "JidoCluster.Test.DockerHost.RPC.run(\"" <> encoded <> "\")"
    seconds = div(timeout + 999, 1_000) + 5

    body = %{
      "AttachStdin" => false,
      "AttachStdout" => true,
      "AttachStderr" => true,
      "Tty" => false,
      "WorkingDir" => "/workspace/docker_host",
      "Cmd" => ["timeout", "--signal=KILL", "#{seconds}s", @release, "rpc", expression]
    }

    case HTTP.request(config, :post, "/containers/" <> container <> "/exec", body) do
      {:ok, 201, %{"Id" => id}} when is_binary(id) and byte_size(id) == 64 ->
        if String.match?(id, ~r/\A[0-9a-f]+\z/), do: {:ok, id}, else: :error

      _ ->
        :error
    end
  end

  defp start(config, exec, timeout) do
    {base, socket} = config.endpoint
    deadline = timeout + 10_000

    options = [
      method: :post,
      url: base <> "/" <> config.api_version <> "/exec/" <> exec <> "/start",
      json: %{"Detach" => false, "Tty" => false},
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      finch: [
        conn_opts: [transport_opts: [timeout: config.timeout]],
        pool_timeout: config.timeout,
        receive_timeout: deadline,
        request_timeout: deadline
      ],
      into: &collect/2
    ]

    options = if socket, do: Keyword.put(options, :unix_socket, socket), else: options

    case Req.request(options) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) -> frames(bytes, "")
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp collect({:data, bytes}, {request, response}) do
    previous = response.body || ""

    if byte_size(previous) + byte_size(bytes) <= @limit,
      do: {:cont, {request, %{response | body: previous <> bytes}}},
      else: {:halt, {request, %{response | body: :oversized}}}
  end

  # Non-TTY Engine exec uses an eight-byte stream header. stderr is consumed
  # but never returned, because a failed command can print environment data.
  defp frames(<<>>, stdout), do: {:ok, stdout}

  defp frames(<<stream, 0, 0, 0, size::unsigned-big-32, rest::binary>>, stdout)
       when stream in [1, 2] and byte_size(rest) >= size do
    <<data::binary-size(size), next::binary>> = rest
    frames(next, if(stream == 1, do: stdout <> data, else: stdout))
  end

  defp frames(_, _), do: :error

  defp finished(config, exec, container) do
    case HTTP.request(config, :get, "/exec/" <> exec <> "/json") do
      {:ok, 200, %{"ID" => ^exec, "ContainerID" => ^container, "Running" => false, "ExitCode" => 0}} -> :ok
      _ -> :error
    end
  end
end
