defmodule Jido.Cluster.RuntimeSnapshot do
  @moduledoc """
  Cluster-safe snapshot envelope for runtime handoff and replica sync.

  The snapshot transfers the agent runtime together with the ownership contract
  that the target runtime should adopt: `cluster_role`, `epoch`, `seq`,
  `primary`, and `standby`.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              epoch: Zoi.integer(description: "Ownership epoch") |> Zoi.min(0) |> Zoi.default(0),
              seq: Zoi.integer(description: "Replicated sequence") |> Zoi.min(0) |> Zoi.default(0),
              agent_module: Zoi.atom(description: "Agent module") |> Zoi.optional(),
              cluster_role: Zoi.atom(description: "Target cluster role") |> Zoi.default(:primary),
              primary: Zoi.atom(description: "Primary node"),
              standby: Zoi.atom(description: "Standby node") |> Zoi.optional(),
              agent_snapshot: Zoi.map(description: "Raw AgentServer cluster snapshot")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the validation schema for runtime handoff snapshots.
  """
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a validated runtime handoff snapshot.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, _} <- Jido.Cluster.Ownership.validate_role(Map.get(attrs, :cluster_role, :primary)) do
      Zoi.parse(@schema, attrs)
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("RuntimeSnapshot requires a keyword list or map")}

  @doc """
  Builds a validated runtime handoff snapshot or raises a validation error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid runtime snapshot", %{details: reason})
    end
  end
end
