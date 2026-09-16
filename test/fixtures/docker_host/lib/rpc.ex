defmodule JidoCluster.Test.DockerHost.RPC do
  @moduledoc false
  @request_limit 32_768
  @reply_limit 131_072

  # This is a trusted test transport, like the native :peer channel. ETF values
  # here are not journal records or provider observations. No input comes from
  # an SDK endpoint. The Docker Engine already authorizes command execution.
  def request(module, function, args, timeout) do
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    value = {id, module, function, args, timeout}

    if valid_request?(value) and :erlang.external_size(value) <= @request_limit,
      do: {:ok, id, value |> :erlang.term_to_binary() |> Base.encode64()},
      else: {:error, :invalid_rpc_request}
  end

  def run(encoded) do
    case invoke(encoded) do
      {:ok, id, result} ->
        bytes = :erlang.term_to_binary({id, result})
        IO.puts("JIDO_RPC:" <> id <> ":" <> Base.encode64(bytes))
        :ok

      {:error, _} ->
        IO.puts("JIDO_RPC:invalid_request")
        :error
    end
  end

  def invoke(encoded) do
    with {:ok, request} <- decode(encoded, @request_limit),
         true <- valid_request?(request) do
      {id, module, function, args, timeout} = request
      result = execute(module, function, args, timeout)
      result = if :erlang.external_size(result) <= @reply_limit, do: result, else: {:error, :rpc_reply_limit}
      {:ok, id, result}
    else
      _ -> {:error, :invalid_rpc_request}
    end
  end

  def response(id, output) when is_binary(output) and byte_size(output) <= 262_144 do
    prefix = "JIDO_RPC:" <> id <> ":"
    lines = output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix))

    with [line] <- lines,
         {:ok, {^id, result}} <- decode(String.replace_prefix(line, prefix, ""), @reply_limit + 128),
         true <- match?({:ok, _}, result) or match?({:error, reason} when is_atom(reason), result) do
      result
    else
      _ -> {:error, :invalid_rpc_response}
    end
  end

  def response(_, _), do: {:error, :invalid_rpc_response}

  defp valid_request?({id, module, function, args, timeout}) do
    is_binary(id) and byte_size(id) == 32 and String.match?(id, ~r/\A[0-9a-f]+\z/) and
      is_atom(module) and is_atom(function) and is_list(args) and length(args) <= 32 and
      is_integer(timeout) and timeout in 1..40_000
  end

  defp valid_request?(_), do: false

  defp decode(encoded, limit) when is_binary(encoded) and byte_size(encoded) <= div((limit + 2) * 4, 3) do
    with {:ok, <<131, tag, _::binary>> = bytes} <- Base.decode64(encoded),
         true <- tag != 80 and byte_size(bytes) <= limit,
         {value, used} <- :erlang.binary_to_term(bytes, [:used]),
         true <- used == byte_size(bytes) do
      {:ok, value}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp decode(_, _), do: :error

  defp execute(module, function, args, timeout) do
    previous = Process.flag(:trap_exit, true)
    task = Task.async(fn -> apply_safely(module, function, args) end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _} -> {:error, :rpc_failed}
        nil -> {:error, :rpc_timeout}
      end

    receive do
      {:EXIT, pid, _} when pid == task.pid -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, previous)
    result
  end

  defp apply_safely(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    _ -> {:error, :rpc_failed}
  catch
    _, _ -> {:error, :rpc_failed}
  end
end
