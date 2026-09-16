defmodule Jido.Cluster.HostProvider.Docker.HTTP do
  @moduledoc false
  @compile {:no_warn_undefined, Req}
  @limit 262_144

  @doc "Makes one bounded local Engine request without retries or redirects."
  @spec request(map(), atom(), String.t(), map() | nil) :: {:ok, non_neg_integer(), term()} | {:error, atom()}
  def request(config, method, path, body \\ nil) do
    {base, socket} = config.endpoint

    options = [
      method: method,
      url: base <> "/" <> config.api_version <> path,
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      finch: [
        conn_opts: [transport_opts: [timeout: config.timeout]],
        pool_timeout: config.timeout,
        receive_timeout: config.timeout,
        request_timeout: config.timeout
      ],
      into: &collect/2
    ]

    options = if socket, do: Keyword.put(options, :unix_socket, socket), else: options
    options = if body, do: Keyword.put(options, :json, body), else: options

    if Code.ensure_loaded?(Req) do
      case Req.request(options) do
        {:ok, %{body: :oversized}} -> {:error, :docker_response_limit}
        {:ok, %{status: status, body: bytes}} -> decode(status, bytes)
        _ -> {:error, :docker_unavailable}
      end
    else
      {:error, :docker_dependency_missing}
    end
  rescue
    _ -> {:error, :docker_unavailable}
  catch
    :exit, _ -> {:error, :docker_unavailable}
  end

  defp collect({:data, data}, {request, response}) do
    previous = response.body || ""

    if byte_size(previous) + byte_size(data) <= @limit,
      do: {:cont, {request, %{response | body: previous <> data}}},
      else: {:halt, {request, %{response | body: :oversized}}}
  end

  defp decode(status, bytes) when bytes in [nil, ""], do: {:ok, status, nil}

  defp decode(status, bytes) do
    case Jason.decode(bytes) do
      {:ok, body} -> {:ok, status, body}
      _ -> {:error, :docker_invalid_response}
    end
  end
end
