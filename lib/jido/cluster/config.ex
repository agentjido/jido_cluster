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

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def new(nil), do: Zoi.parse(@schema, %{replication: Replication.new!(nil)})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, replication} <- Replication.new(Map.get(attrs, :replication)),
         {:ok, _} <- validate_partition_policy(Map.get(attrs, :partition_policy, :freeze)),
         {:ok, _} <- validate_handoff_mode(Map.get(attrs, :handoff_mode, :hibernate_thaw)),
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

  @spec new!(keyword() | map() | nil) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid cluster config", %{details: reason})
    end
  end

  @spec merge(t() | nil, map() | keyword()) :: t()
  def merge(nil, attrs), do: new!(attrs)
  def merge(%__MODULE__{} = config, attrs) when is_list(attrs), do: merge(config, Map.new(attrs))

  def merge(%__MODULE__{} = config, attrs) when is_map(attrs) do
    config
    |> Map.from_struct()
    |> Map.merge(attrs)
    |> new!()
  end

  @spec validate_partition_policy(term()) :: {:ok, :freeze | :soft_owner} | {:error, term()}
  def validate_partition_policy(:freeze), do: {:ok, :freeze}
  def validate_partition_policy(:soft_owner), do: {:ok, :soft_owner}

  def validate_partition_policy(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid partition_policy: #{inspect(other)}")}
  end

  @spec validate_handoff_mode(term()) :: {:ok, :hibernate_thaw | :live_transfer} | {:error, term()}
  def validate_handoff_mode(:hibernate_thaw), do: {:ok, :hibernate_thaw}
  def validate_handoff_mode(:live_transfer), do: {:ok, :live_transfer}

  def validate_handoff_mode(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid handoff_mode: #{inspect(other)}")}
  end

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
end
