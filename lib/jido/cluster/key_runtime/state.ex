defmodule Jido.Cluster.KeyRuntime.State do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              agent_module: Zoi.atom(description: "Agent module"),
              jido: Zoi.atom(description: "Jido instance"),
              agent_opts: Zoi.list(Zoi.any(), description: "Extra agent options") |> Zoi.default([]),
              primary: Zoi.atom(description: "Primary node"),
              standby: Zoi.atom(description: "Standby node") |> Zoi.optional(),
              role: Zoi.atom(description: "Local runtime role") |> Zoi.default(:primary),
              epoch: Zoi.integer(description: "Ownership epoch") |> Zoi.min(0) |> Zoi.default(0),
              seq: Zoi.integer(description: "Replicated sequence") |> Zoi.min(0) |> Zoi.default(0),
              promotion_timeout_ms:
                Zoi.integer(description: "Promotion timeout")
                |> Zoi.min(1)
                |> Zoi.default(5_000),
              promotion_timer: Zoi.any(description: "Promotion timer reference") |> Zoi.optional(),
              agent_pid: Zoi.any(description: "Hosted agent pid") |> Zoi.optional(),
              initial_state: Zoi.map(description: "Initial agent state") |> Zoi.default(%{})
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
    with {:ok, _} <- Jido.Cluster.Ownership.validate_role(Map.get(attrs, :role, :primary)) do
      Zoi.parse(@schema, attrs)
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("KeyRuntime.State requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid key runtime state", %{details: reason})
    end
  end
end
