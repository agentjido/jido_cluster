defmodule Jido.Cluster.Topology.View do
  @moduledoc """
  Topology snapshot for placement and quorum decisions.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              nodes: Zoi.list(Zoi.atom(), description: "Visible connected nodes") |> Zoi.default([]),
              leader: Zoi.atom(description: "Deterministic leader node") |> Zoi.optional(),
              quorum_met?: Zoi.boolean(description: "Whether quorum is currently satisfied") |> Zoi.default(true),
              observed_at: Zoi.integer(description: "Monotonic snapshot timestamp (ms)") |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the validation schema for a topology snapshot.
  """
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a validated topology snapshot.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Topology.View requires a keyword list or map")}

  @doc """
  Builds a validated topology snapshot or raises a validation error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, view} -> view
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid topology view", %{details: reason})
    end
  end
end
