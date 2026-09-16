defmodule Jido.Cluster.HostProvider.Docker.Options do
  @moduledoc false
  @keys [:endpoint, :engine_id, :container, :borrowed_id, :timeout, :api_version]

  @doc "Validates local Docker configuration without an external request."
  @spec new(term()) :: {:ok, map()} | {:error, :invalid_docker_options}
  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- Keyword.keys(options) -- @keys == [],
         true <- length(options) == length(Enum.uniq_by(options, &elem(&1, 0))),
         {:ok, endpoint} <- endpoint(options[:endpoint]),
         true <- identifier?(options[:engine_id]),
         timeout = Keyword.get(options, :timeout, 1_000),
         true <- is_integer(timeout) and timeout in 10..10_000,
         version = Keyword.get(options, :api_version, "v1.47"),
         true <- is_binary(version) and Regex.match?(~r/^v1\.[0-9]{2,3}$/, version),
         true <- source?(options[:container], options[:borrowed_id]) do
      {:ok,
       %{
         endpoint: endpoint,
         engine_id: options[:engine_id],
         container: options[:container],
         borrowed_id: options[:borrowed_id],
         timeout: timeout,
         api_version: version
       }}
    else
      _ -> {:error, :invalid_docker_options}
    end
  end

  def new(_), do: {:error, :invalid_docker_options}

  @doc "Checks a full immutable Docker container ID."
  @spec container_id?(term()) :: boolean()
  def container_id?(id), do: is_binary(id) and Regex.match?(~r/^[a-f0-9]{64}$/, id)

  defp endpoint({:unix, path}) when is_binary(path) do
    if Path.type(path) == :absolute and byte_size(path) <= 1_024, do: {:ok, {"http://docker", path}}, else: :error
  end

  defp endpoint({:http, url}) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil and uri.path in [nil, "", "/"],
       do: {:ok, {String.trim_trailing(url, "/"), nil}},
       else: :error
  end

  defp endpoint(_), do: :error
  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
  defp source?(nil, id), do: container_id?(id)

  defp source?(container, nil) when is_map(container) and not is_struct(container) do
    allowed = ~w(Image Cmd Entrypoint Env HostConfig NetworkingConfig WorkingDir User)
    env = Map.get(container, "Env", [])
    host = Map.get(container, "HostConfig", %{})

    Map.keys(container) -- allowed == [] and identifier?(container["Image"]) and
      is_map(host) and Map.get(host, "AutoRemove", false) == false and
      is_list(env) and Enum.all?(env, &environment?/1) and portable?(container)
  end

  defp source?(_, _), do: false
  defp environment?(value), do: is_binary(value) and not String.starts_with?(value, "JIDO_CLUSTER_HOST_")

  defp portable?(container) do
    case Jason.encode(container) do
      {:ok, bytes} -> byte_size(bytes) <= 65_536 and Jason.decode(bytes) == {:ok, container}
      _ -> false
    end
  rescue
    _ -> false
  end
end
