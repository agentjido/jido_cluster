defmodule Jido.Cluster.HostProvider.Docker do
  @moduledoc """
  Optional local Docker Engine adapter for a trusted prepared BEAM container.

  Requires the optional `:req` dependency. Options are `:endpoint` (an absolute
  `{:unix, path}` or loopback `{:http, url}`), the expected `/info` `:engine_id`,
  and a `:container` Engine create object with a prepared `Image`. `:timeout`
  bounds each HTTP phase (default 1000 ms, maximum 10000); `:api_version` defaults
  to `v1.47`. Acquire makes at most five sequential API requests; inspect uses
  two and release uses three. Discovery uses at most the limit plus two. Bodies
  are limited to 256 KiB. This adapter does not pull or build images.

  The create object can set Cmd, Entrypoint, Env, HostConfig, NetworkingConfig,
  WorkingDir, and User. AutoRemove and reserved environment overrides are refused.
  The adapter supplies `JIDO_CLUSTER_HOST_STEP` (JSON) and `JIDO_CLUSTER_HOST_NODE`.
  The prepared application starts Core and HostRuntime with the supplied step.
  Network access, the BEAM cookie, code, and persistence remain application setup.

  Instead of `:container`, use a full `:borrowed_id` to inspect an existing
  container. In this mode acquire and release always reject effects. Configure
  the service ownership as `:borrowed` too. Engine identity is checked before
  absence can be reported. Provider options and Engine response bodies never
  become error details or durable resource records.

  Create uses a deterministic name and exact step labels. A lost result remains
  indeterminate; the service inspects the original step. It never repeats create.
  A conflict is inspected without starting another container. Release inspects
  the exact immutable ID and deletes that ID, never a name. Deletion does not
  remove volumes. A caller must inspect after accepted release. A late start for
  a deleted ID cannot create a replacement. Unknown creation with no observed
  resource remains uncertain because an absent read cannot exclude late creation.
  The scope journal prevents repeated create after an attempt has executed. This
  stateless adapter does not keep tombstones for manual calls after deletion.
  """
  @behaviour Jido.Cluster.HostProvider
  alias Jido.Cluster.HostProvider.Docker.{HTTP, Options}
  alias Jido.Cluster.HostProvider.{Resource, Step}
  @step_label "io.jido.cluster.step"
  @incarnation_label "io.jido.cluster.incarnation"
  @namespace_label "io.jido.cluster.namespace"
  @scope_label "io.jido.cluster.scope"

  @impl true
  def validate_options(options) do
    with {:ok, _} <- Options.new(options), do: :ok
  end

  @impl true
  def acquire(step, options) do
    with {:ok, config} <- Options.new(options),
         true <- config.borrowed_id == nil,
         {:ok, ^step} <- Step.new(Map.from_struct(step)),
         :ok <- engine(config) do
      case observation(step, name(step), config) do
        {:ok, :absent} -> create(step, config)
        {:ok, resource} -> {:ok, resource}
        {:error, reason} -> {:error, {:indeterminate, reason}}
      end
    else
      false -> {:error, {:rejected, :borrowed_resource}}
      {:error, reason} -> {:error, {:rejected, reason}}
    end
  end

  @impl true
  def inspect(step, options) do
    with {:ok, config} <- Options.new(options),
         :ok <- engine(config),
         do: observation(step, config.borrowed_id || name(step), config)
  end

  @impl true
  def release(resource, options) do
    with {:ok, config} <- Options.new(options),
         true <- config.borrowed_id == nil,
         true <- Options.container_id?(resource.id),
         :ok <- engine(config),
         {:ok, current} <- observation(resource.step, resource.id, config) do
      release_current(resource, current, config)
    else
      false -> {:error, {:rejected, :docker_release_refused}}
      {:error, reason} -> {:error, {:indeterminate, reason}}
    end
  end

  @impl true
  def discover({namespace, scope}, limit, options) when is_binary(namespace) and is_binary(scope) and limit in 1..32 do
    with {:ok, config} <- Options.new(options),
         true <- config.borrowed_id == nil,
         :ok <- engine(config) do
      filters = Jason.encode!(%{"label" => [@namespace_label <> "=" <> namespace, @scope_label <> "=" <> scope]})
      query = URI.encode_query(%{"all" => "true", "limit" => limit + 1, "filters" => filters})
      discover_records(HTTP.request(config, :get, "/containers/json?" <> query), {namespace, scope}, limit, config)
    else
      false -> {:error, :borrowed_resource}
      error -> error
    end
  end

  def discover(_, _, _), do: {:error, :invalid_discovery_limit}

  defp discover_records({:ok, 200, records}, scope, limit, config) when is_list(records) and length(records) <= limit do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, resources} ->
      case discovered(record, scope, config) do
        {:ok, %Resource{} = resource} -> {:cont, {:ok, resources ++ [resource]}}
        _ -> {:halt, {:error, :docker_discovery_unconfirmed}}
      end
    end)
  end

  defp discover_records({:ok, 200, records}, _, _, _) when is_list(records), do: {:error, :discovery_limit}
  defp discover_records(_, _, _, _), do: {:error, :docker_discovery_unavailable}

  defp discovered(%{"Id" => id, "Labels" => labels}, {namespace, scope}, config) when is_map(labels) do
    with true <- Options.container_id?(id),
         encoded when is_binary(encoded) <- labels[@step_label],
         {:ok, record} <- Jason.decode(encoded),
         {:ok, %Step{namespace: ^namespace, scope: ^scope} = step} <- Step.from_record(record),
         do: observation(step, id, config)
  end

  defp discovered(_, _, _), do: :error

  defp engine(config) do
    case HTTP.request(config, :get, "/info") do
      {:ok, 200, %{"ID" => id}} when id == config.engine_id -> :ok
      {:ok, 200, _} -> {:error, :docker_engine_changed}
      {:ok, _, _} -> {:error, :docker_engine_unavailable}
      error -> error
    end
  end

  defp create(step, config) do
    case HTTP.request(config, :post, "/containers/create?name=" <> name(step), create_body(step, config)) do
      {:ok, 201, %{"Id" => id}} -> start(step, id, config)
      {:ok, 409, _} -> unknown(observation(step, name(step), config))
      {:ok, status, _} when status in [400, 401, 403, 404] -> {:error, {:rejected, {:docker_create_rejected, status}}}
      {:ok, _, _} -> {:error, {:indeterminate, :docker_create_unconfirmed}}
      {:error, reason} -> {:error, {:indeterminate, reason}}
    end
  end

  defp create_body(step, config) do
    env =
      Map.get(config.container, "Env", []) ++
        ["JIDO_CLUSTER_HOST_STEP=" <> Jason.encode!(Step.to_record(step)), "JIDO_CLUSTER_HOST_NODE=" <> step.host]

    labels = %{
      @step_label => Jason.encode!(Step.to_record(step)),
      @incarnation_label => Jido.generate_id(),
      @namespace_label => step.namespace,
      @scope_label => step.scope
    }

    config.container |> Map.put("Env", env) |> Map.put("Labels", labels)
  end

  defp start(step, id, config) do
    if Options.container_id?(id) do
      case HTTP.request(config, :post, "/containers/" <> id <> "/start") do
        {:ok, status, _} when status in [204, 304] -> unknown(observation(step, id, config))
        _ -> {:error, {:indeterminate, :docker_start_unconfirmed}}
      end
    else
      {:error, {:indeterminate, :docker_invalid_container}}
    end
  end

  defp observation(step, id, config) do
    case HTTP.request(config, :get, "/containers/" <> id <> "/json") do
      {:ok, 404, _} -> {:ok, :absent}
      {:ok, 200, record} -> inspected(step, id, record, config)
      {:ok, _, _} -> {:error, :docker_inspection_unavailable}
      error -> error
    end
  end

  defp inspected(step, requested, %{"Id" => id} = record, config) do
    if Options.container_id?(requested) and requested != id,
      do: {:error, :docker_resource_changed},
      else: resource(step, record, config)
  end

  defp inspected(_, _, _, _), do: {:error, :docker_invalid_container}

  defp resource(
         step,
         %{"Id" => id, "Created" => created, "State" => %{"Status" => status}, "Config" => %{"Labels" => labels}},
         config
       ) do
    labels = labels || %{}

    with true <- Options.container_id?(id),
         {:ok, incarnation} <- identity(step, id, created, labels, config),
         state when not is_nil(state) <- state(status) do
      Resource.new(step, id, incarnation, state)
    else
      _ -> {:error, :docker_resource_changed}
    end
  end

  defp resource(_, _, _), do: {:error, :docker_invalid_container}

  defp identity(_, id, created, _, %{borrowed_id: id}) when is_binary(id), do: {:ok, created}

  defp identity(step, _, _, labels, %{borrowed_id: nil}) when is_map(labels) do
    with encoded when is_binary(encoded) <- Map.get(labels, @step_label),
         {:ok, record} <- Jason.decode(encoded),
         {:ok, ^step} <- Step.from_record(record),
         do: {:ok, labels[@incarnation_label]}
  end

  defp identity(_, _, _, _, _), do: :error

  defp state("running"), do: :running
  defp state(status) when status in ["created", "restarting"], do: :starting
  defp state(status) when status in ["paused", "exited", "dead", "removing"], do: :stopped
  defp state(_), do: nil

  defp release_current(_, :absent, _), do: :ok

  defp release_current(resource, current, config) do
    if Resource.same?(resource, current) do
      case HTTP.request(config, :delete, "/containers/" <> resource.id <> "?force=true&v=false") do
        {:ok, status, _} when status in [204, 404] -> :ok
        _ -> {:error, {:indeterminate, :docker_delete_unconfirmed}}
      end
    else
      {:error, {:rejected, :stale_resource}}
    end
  end

  defp unknown({:ok, :absent}), do: {:error, {:indeterminate, :docker_resource_absent}}
  defp unknown({:error, reason}), do: {:error, {:indeterminate, reason}}
  defp unknown(result), do: result

  defp name(step),
    do: "jido-cluster-" <> (:crypto.hash(:sha256, Jason.encode!(Step.to_record(step))) |> Base.encode16(case: :lower))
end
