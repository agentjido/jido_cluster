defmodule JidoCluster.Test.DockerAPI do
  @moduledoc false
  use GenServer
  import ExUnit.Assertions

  def start_link(replies), do: GenServer.start_link(__MODULE__, replies)
  def endpoint(server), do: GenServer.call(server, :endpoint)
  def requests(server), do: GenServer.call(server, :requests)
  def remaining(server), do: GenServer.call(server, :remaining)
  def replies(server, replies), do: GenServer.call(server, {:replies, replies})

  @impl true
  def init(%{path: path, replies: replies}), do: listen([ifaddr: {:local, path}], replies, path)
  def init(replies), do: listen([ip: {127, 0, 0, 1}], replies, nil)

  defp listen(address, replies, path) do
    Process.flag(:trap_exit, true)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true] ++ address)

    endpoint =
      if path do
        {:unix, path}
      else
        {:ok, {_, port}} = :inet.sockname(socket)
        {:http, "http://127.0.0.1:#{port}"}
      end

    owner = self()
    worker = spawn_link(fn -> accept(socket, owner) end)
    {:ok, %{socket: socket, worker: worker, endpoint: endpoint, path: path, replies: replies, requests: []}}
  end

  @impl true
  def handle_call(:endpoint, _, state), do: {:reply, state.endpoint, state}
  def handle_call(:requests, _, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:remaining, _, state), do: {:reply, state.replies, state}
  def handle_call({:replies, replies}, _, state), do: {:reply, :ok, %{state | replies: replies}}

  def handle_call({:request, request}, _, state) do
    case state.replies do
      [reply | rest] -> {:reply, reply, %{state | replies: rest, requests: [request | state.requests]}}
      [] -> {:reply, {500, %{"message" => "unexpected request"}}, %{state | requests: [request | state.requests]}}
    end
  end

  @impl true
  def terminate(_, state) do
    monitor = Process.monitor(state.worker)
    Process.exit(state.worker, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    :gen_tcp.close(state.socket)
    if state.path && File.exists?(state.path), do: File.rm!(state.path)
  end

  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = read_request(socket, "")
        reply = GenServer.call(owner, {:request, request})
        reply = if is_function(reply, 1), do: reply.(request), else: reply
        respond(socket, reply)
        :gen_tcp.close(socket)
        accept(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [first | fields] = String.split(headers, "\r\n")
        [method, path, _] = String.split(first, " ")

        size = Enum.find_value(fields, 0, &content_length/1)

        {:ok, body} = read_body(socket, body, size)
        {:ok, %{method: method, path: path, body: if(body == "", do: nil, else: Jason.decode!(body))}}

      [_] ->
        with {:ok, more} <- :gen_tcp.recv(socket, 0, 5_000), do: read_request(socket, bytes <> more)
    end
  end

  defp content_length(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] -> if String.downcase(key) == "content-length", do: value |> String.trim() |> String.to_integer()
      _ -> nil
    end
  end

  defp read_body(_, bytes, size) when byte_size(bytes) >= size, do: {:ok, bytes}

  defp read_body(socket, bytes, size) do
    with {:ok, more} <- :gen_tcp.recv(socket, size - byte_size(bytes), 5_000), do: {:ok, bytes <> more}
  end

  defp respond(_, :close), do: :ok

  defp respond(_, :hold) do
    receive do
      :finish -> :ok
    end
  end

  defp respond(socket, {status, value}) when is_integer(status) do
    body = if is_binary(value), do: value, else: if(is_nil(value), do: "", else: Jason.encode!(value))
    response(socket, status, "application/json", body)
  end

  defp respond(socket, {:stream, bytes}),
    do: response(socket, 200, "application/vnd.docker.multiplexed-stream", bytes)

  defp response(socket, status, type, body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Result\r\nContent-Type: #{type}\r\nConnection: close\r\nContent-Length: #{byte_size(body)}\r\n\r\n",
      body
    ])
  end
end
