defmodule Jido.Cluster.Placement do
  @moduledoc """
  Deterministic replica placement for a single clustered key.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              primary: Zoi.atom(description: "Primary node") |> Zoi.optional(),
              standby: Zoi.atom(description: "Standby node") |> Zoi.optional(),
              nodes: Zoi.list(Zoi.atom(), description: "Ordered placement nodes") |> Zoi.default([])
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
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Placement requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, placement} -> placement
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid placement", %{details: reason})
    end
  end
end
