defmodule Jido.Cluster.Config do
  @moduledoc """
  Canonical manager configuration for clustered Jido runtimes.
  """

  alias Jido.Cluster.LeaseBackend
  alias Jido.Cluster.Replication

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.atom(description: "Manager name") |> Zoi.optional(),
              agent: Zoi.atom(description: "Agent module") |> Zoi.optional(),
              jido: Zoi.atom(description: "Jido instance name") |> Zoi.default(Jido),
              agent_opts: Zoi.list(Zoi.any(), description: "Extra agent options") |> Zoi.default([]),
              storage: Zoi.any(description: "Optional storage backend") |> Zoi.default(nil),
              idle_timeout: Zoi.any(description: "Idle timeout for managed agents") |> Zoi.default(:infinity),
              partition_policy:
                Zoi.atom(description: "Cluster partition policy")
                |> Zoi.default(:freeze),
              min_quorum_nodes:
                Zoi.integer(description: "Minimum quorum node count")
                |> Zoi.min(1)
                |> Zoi.default(1),
              handoff_mode:
                Zoi.atom(description: "Handoff mode")
                |> Zoi.default(:hibernate_thaw),
              coordination_backend:
                Zoi.any(description: "Coordination backend")
                |> Zoi.default(:connected_beam),
              replication:
                Replication.schema()
                |> Zoi.default(Replication.new!(nil))
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the validation schema used to normalize clustered manager options.
  """
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a validated manager configuration.
  """
  @spec new(keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def new(nil), do: Zoi.parse(@schema, %{replication: Replication.new!(nil)})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    handoff_mode = Map.get(attrs, :handoff_mode, :hibernate_thaw)

    with {:ok, replication} <- Replication.new(Map.get(attrs, :replication, default_replication(handoff_mode))),
         {:ok, _} <- validate_partition_policy(Map.get(attrs, :partition_policy, :freeze)),
         {:ok, _} <- validate_handoff_mode(handoff_mode),
         :ok <- validate_replication_compatibility(handoff_mode, replication),
         {:ok, coordination_backend} <-
           validate_coordination_backend(Map.get(attrs, :coordination_backend, :connected_beam)) do
      attrs =
        attrs
        |> Map.put(:replication, replication)
        |> Map.put(:coordination_backend, coordination_backend)

      Zoi.parse(@schema, attrs)
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Config requires a keyword list or map")}

  @doc """
  Builds a validated manager configuration or raises a validation error.
  """
  @spec new!(keyword() | map() | nil) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid cluster config", %{details: reason})
    end
  end

  @doc """
  Merges new attributes into an existing manager configuration and revalidates it.
  """
  @spec merge(t() | nil, map() | keyword()) :: t()
  def merge(nil, attrs), do: new!(attrs)
  def merge(%__MODULE__{} = config, attrs) when is_list(attrs), do: merge(config, Map.new(attrs))

  def merge(%__MODULE__{} = config, attrs) when is_map(attrs) do
    config
    |> Map.from_struct()
    |> Map.merge(attrs)
    |> new!()
  end

  @doc """
  Validates the configured partition behavior.
  """
  @spec validate_partition_policy(term()) :: {:ok, :freeze | :soft_owner} | {:error, term()}
  def validate_partition_policy(:freeze), do: {:ok, :freeze}
  def validate_partition_policy(:soft_owner), do: {:ok, :soft_owner}

  def validate_partition_policy(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid partition_policy: #{inspect(other)}")}
  end

  @doc """
  Validates the configured runtime handoff mode.
  """
  @spec validate_handoff_mode(term()) :: {:ok, :hibernate_thaw | :live_transfer} | {:error, term()}
  def validate_handoff_mode(:hibernate_thaw), do: {:ok, :hibernate_thaw}
  def validate_handoff_mode(:live_transfer), do: {:ok, :live_transfer}

  def validate_handoff_mode(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid handoff_mode: #{inspect(other)}")}
  end

  @doc """
  Normalizes the coordination backend configuration.
  """
  @spec validate_coordination_backend(term()) :: {:ok, term()} | {:error, term()}
  def validate_coordination_backend(:connected_beam), do: {:ok, :connected_beam}

  def validate_coordination_backend({:bedrock_lease, %LeaseBackend{} = backend}),
    do: {:ok, {:bedrock_lease, backend}}

  def validate_coordination_backend({:bedrock_lease, lease_opts}) when is_list(lease_opts) do
    with {:ok, %LeaseBackend{} = backend} <- LeaseBackend.new(lease_opts) do
      {:ok, {:bedrock_lease, backend}}
    end
  end

  def validate_coordination_backend(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid coordination_backend: #{inspect(other)}")}
  end

  defp default_replication(:live_transfer), do: %{replicas: 0, mode: :sync, promotion_timeout_ms: 5_000}
  defp default_replication(_handoff_mode), do: nil

  defp validate_replication_compatibility(:live_transfer, %Replication{mode: :sync}), do: :ok
  defp validate_replication_compatibility(:hibernate_thaw, %Replication{}), do: :ok

  defp validate_replication_compatibility(:live_transfer, %Replication{} = replication) do
    {:error,
     Jido.Cluster.Error.validation_error(
       "live_transfer requires sync replication mode",
       %{details: %{replication: replication}}
     )}
  end
end
