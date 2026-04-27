defmodule Jido.Cluster.LeaseClaim do
  @moduledoc """
  Lease acquisition request shape for disconnected-island coordination.

  Claims are ephemeral requests that ask Bedrock to grant or renew ownership for
  one `{manager, key}` pair under a specific cadence.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.any(description: "Manager name"),
              key: Zoi.any(description: "Logical agent key"),
              claimant: Zoi.any(description: "Claimant identity"),
              requested_at_ms:
                Zoi.integer(description: "Request timestamp in milliseconds")
                |> Zoi.min(0),
              ttl_ms: Zoi.integer(description: "Requested TTL in milliseconds") |> Zoi.min(1),
              renew_interval_ms:
                Zoi.integer(description: "Requested renewal interval in milliseconds")
                |> Zoi.min(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Returns the validation schema for a lease acquisition request.
  """
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc """
  Builds a validated lease acquisition request.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, claim} <- Zoi.parse(@schema, attrs),
         :ok <- validate_timing(claim) do
      {:ok, claim}
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Lease claim requires a keyword list or map")}

  @doc """
  Builds a validated lease acquisition request or raises a validation error.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, claim} -> claim
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid lease claim", %{details: reason})
    end
  end

  defp validate_timing(%__MODULE__{renew_interval_ms: renew_interval_ms, ttl_ms: ttl_ms})
       when renew_interval_ms < ttl_ms,
       do: :ok

  defp validate_timing(%__MODULE__{} = claim) do
    {:error,
     Jido.Cluster.Error.validation_error(
       "lease claim renew_interval_ms must be less than ttl_ms",
       %{details: %{renew_interval_ms: claim.renew_interval_ms, ttl_ms: claim.ttl_ms}}
     )}
  end
end
