defmodule Jido.Cluster.Replication do
  @moduledoc """
  Replication policy for a clustered Jido manager.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              replicas:
                Zoi.integer(description: "Number of standby replicas")
                |> Zoi.min(0)
                |> Zoi.max(1)
                |> Zoi.default(0),
              mode:
                Zoi.atom(description: "Replication mode (:async | :sync)")
                |> Zoi.default(:async),
              promotion_timeout_ms:
                Zoi.integer(description: "Promotion timeout in milliseconds")
                |> Zoi.min(1)
                |> Zoi.default(5_000)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the validation schema for replication options.
  """
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a validated replication policy.
  """
  @spec new(keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def new(nil), do: Zoi.parse(@schema, %{})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :promotion_timeout_ms, 5_000)

    with {:ok, _} <- validate_mode(Map.get(attrs, :mode, :async)) do
      Zoi.parse(@schema, attrs)
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Replication requires a keyword list or map")}

  @doc """
  Builds a validated replication policy or raises a validation error.
  """
  @spec new!(keyword() | map() | nil) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, replication} -> replication
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid replication", %{details: reason})
    end
  end

  @doc """
  Validates the configured replication mode.
  """
  @spec validate_mode(term()) :: {:ok, :async | :sync} | {:error, term()}
  def validate_mode(:async), do: {:ok, :async}
  def validate_mode(:sync), do: {:ok, :sync}

  def validate_mode(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid replication mode: #{inspect(other)}")}
  end
end
