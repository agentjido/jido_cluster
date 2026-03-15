defmodule Jido.Cluster.Ownership do
  @moduledoc """
  Ownership record for one logical clustered key.

  Contract semantics:

  - `role` is the runtime role for this local summary, not a node-wide role.
  - `epoch` advances when ownership meaningfully changes, such as promotion or
    planned handoff.
  - `seq` tracks the last acknowledged replicated update visible to this key.
  - `primary` and `standby` describe the intended replica pair for the current
    cluster view.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              epoch: Zoi.integer(description: "Ownership epoch") |> Zoi.min(0) |> Zoi.default(0),
              seq: Zoi.integer(description: "Last replicated sequence") |> Zoi.min(0) |> Zoi.default(0),
              primary: Zoi.atom(description: "Primary node"),
              standby: Zoi.atom(description: "Standby node") |> Zoi.optional(),
              role: Zoi.atom(description: "Local runtime role") |> Zoi.default(:primary),
              status: Zoi.atom(description: "Ownership status") |> Zoi.default(:owned)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, _} <- validate_role(Map.get(attrs, :role, :primary)),
         {:ok, _} <- validate_status(Map.get(attrs, :status, :owned)) do
      Zoi.parse(@schema, attrs)
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Ownership requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, ownership} -> ownership
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid ownership", %{details: reason})
    end
  end

  @spec validate_role(term()) :: {:ok, :primary | :standby} | {:error, term()}
  def validate_role(:primary), do: {:ok, :primary}
  def validate_role(:standby), do: {:ok, :standby}

  def validate_role(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid ownership role: #{inspect(other)}")}
  end

  @spec validate_status(term()) ::
          {:ok, :starting | :owned | :standby | :promoting | :handoff | :stopped}
          | {:error, term()}
  def validate_status(status) when status in [:starting, :owned, :standby, :promoting, :handoff, :stopped],
    do: {:ok, status}

  def validate_status(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid ownership status: #{inspect(other)}")}
  end
end
