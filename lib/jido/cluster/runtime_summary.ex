defmodule Jido.Cluster.RuntimeSummary do
  @moduledoc """
  Lightweight runtime summary used for routing and coordination.

  `RuntimeSummary` is the manager-facing snapshot used to compare competing
  views of a logical key. `epoch` orders ownership changes, `seq` orders
  acknowledged replicated updates within an epoch, and `agent_pid` is an
  observational handle rather than a durable cluster identity.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              node: Zoi.atom(description: "Node hosting this runtime"),
              role: Zoi.atom(description: "Local runtime role") |> Zoi.default(:primary),
              epoch: Zoi.integer(description: "Ownership epoch") |> Zoi.min(0) |> Zoi.default(0),
              seq: Zoi.integer(description: "Last replicated sequence") |> Zoi.min(0) |> Zoi.default(0),
              primary: Zoi.atom(description: "Primary node"),
              standby: Zoi.atom(description: "Standby node") |> Zoi.optional(),
              status: Zoi.atom(description: "Runtime status") |> Zoi.default(:owned),
              agent_pid: Zoi.any(description: "Agent pid if running") |> Zoi.optional()
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
    with {:ok, _} <- Jido.Cluster.Ownership.validate_role(Map.get(attrs, :role, :primary)),
         {:ok, _} <- Jido.Cluster.Ownership.validate_status(Map.get(attrs, :status, :owned)) do
      Zoi.parse(@schema, attrs)
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("RuntimeSummary requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, summary} -> summary
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid runtime summary", %{details: reason})
    end
  end
end
