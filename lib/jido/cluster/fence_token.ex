defmodule Jido.Cluster.FenceToken do
  @moduledoc """
  Stale-writer rejection token for disconnected-island ownership.

  Every successful lease acquisition issues a new fence token. Writers must
  include the current token to prove they still hold the active lease.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              epoch: Zoi.integer(description: "Monotonic lease epoch") |> Zoi.min(0) |> Zoi.default(0),
              lease_id: Zoi.string(description: "Unique acquisition id"),
              holder: Zoi.any(description: "Lease holder identity"),
              issued_at_ms:
                Zoi.integer(description: "Issuance timestamp in milliseconds")
                |> Zoi.min(0)
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
    do: {:error, Jido.Cluster.Error.validation_error("Fence token requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, token} -> token
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid fence token", %{details: reason})
    end
  end
end
