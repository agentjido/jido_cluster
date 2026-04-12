defmodule Jido.Cluster.Lease do
  @moduledoc """
  Durable lease record for disconnected-island ownership.

  A lease is the persisted coordination record that a Bedrock-backed backend
  uses to decide who may execute a logical singleton outside connected BEAM
  membership.
  """

  alias Jido.Cluster.FenceToken

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              holder: Zoi.any(description: "Current lease holder"),
              lease_id: Zoi.string(description: "Unique acquisition id"),
              epoch: Zoi.integer(description: "Monotonic lease epoch") |> Zoi.min(0) |> Zoi.default(0),
              issued_at_ms:
                Zoi.integer(description: "Lease issuance timestamp in milliseconds")
                |> Zoi.min(0),
              expires_at_ms:
                Zoi.integer(description: "Lease expiry timestamp in milliseconds")
                |> Zoi.min(0),
              ttl_ms: Zoi.integer(description: "Lease TTL in milliseconds") |> Zoi.min(1),
              renew_interval_ms:
                Zoi.integer(description: "Renew cadence in milliseconds")
                |> Zoi.min(1),
              status:
                Zoi.atom(description: "Lease lifecycle status")
                |> Zoi.default(:active),
              fence_token: FenceToken.schema()
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
    with {:ok, lease} <- Zoi.parse(@schema, attrs),
         {:ok, _} <- validate_status(Map.get(attrs, :status, :active)),
         :ok <- validate_timing(lease),
         :ok <- validate_fence_alignment(lease) do
      {:ok, lease}
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Lease requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, lease} -> lease
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid lease", %{details: reason})
    end
  end

  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at_ms: expires_at_ms}, now_ms) when is_integer(now_ms) do
    now_ms >= expires_at_ms
  end

  @spec validate_status(term()) :: {:ok, :active | :released | :expired} | {:error, term()}
  def validate_status(status) when status in [:active, :released, :expired], do: {:ok, status}

  def validate_status(other) do
    {:error, Jido.Cluster.Error.validation_error("invalid lease status: #{inspect(other)}")}
  end

  defp validate_timing(%__MODULE__{
         issued_at_ms: issued_at_ms,
         expires_at_ms: expires_at_ms,
         renew_interval_ms: renew_interval_ms,
         ttl_ms: ttl_ms
       })
       when issued_at_ms < expires_at_ms and renew_interval_ms < ttl_ms,
       do: :ok

  defp validate_timing(%__MODULE__{} = lease) do
    {:error,
     Jido.Cluster.Error.validation_error(
       "lease timing is invalid",
       %{
         details: %{
           issued_at_ms: lease.issued_at_ms,
           expires_at_ms: lease.expires_at_ms,
           renew_interval_ms: lease.renew_interval_ms,
           ttl_ms: lease.ttl_ms
         }
       }
     )}
  end

  defp validate_fence_alignment(%__MODULE__{
         holder: holder,
         lease_id: lease_id,
         epoch: epoch,
         fence_token: %FenceToken{} = fence_token
       }) do
    if fence_token.holder == holder and fence_token.lease_id == lease_id and fence_token.epoch == epoch do
      :ok
    else
      {:error,
       Jido.Cluster.Error.validation_error(
         "lease fence token must match holder, lease_id, and epoch",
         %{details: %{holder: holder, lease_id: lease_id, epoch: epoch, fence_token: fence_token}}
       )}
    end
  end
end
