defmodule Jido.Cluster.LeaseBackend do
  @moduledoc """
  Typed configuration for disconnected-island Bedrock lease coordination.

  This struct normalizes the `{:bedrock_lease, opts}` coordination backend so
  the runtime and tests share one lease cadence and timing contract.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              repo: Zoi.atom(description: "Bedrock repo module"),
              prefix: Zoi.string(description: "Lease key prefix") |> Zoi.default("jido_cluster/leases/"),
              ttl_ms: Zoi.integer(description: "Lease time-to-live in milliseconds") |> Zoi.min(1) |> Zoi.default(15_000),
              renew_interval_ms:
                Zoi.integer(description: "Renewal cadence in milliseconds")
                |> Zoi.min(1)
                |> Zoi.default(5_000),
              clock_skew_ms:
                Zoi.integer(description: "Clock skew budget in milliseconds")
                |> Zoi.min(0)
                |> Zoi.default(500),
              retry_backoff_ms:
                Zoi.integer(description: "Retry backoff in milliseconds")
                |> Zoi.min(1)
                |> Zoi.default(250)
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
    with {:ok, backend} <- Zoi.parse(@schema, attrs),
         :ok <- validate_timing(backend) do
      {:ok, backend}
    end
  end

  def new(_),
    do: {:error, Jido.Cluster.Error.validation_error("Lease backend requires a keyword list or map")}

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, backend} -> backend
      {:error, reason} -> raise Jido.Cluster.Error.validation_error("Invalid lease backend", %{details: reason})
    end
  end

  defp validate_timing(%__MODULE__{renew_interval_ms: renew_interval_ms, ttl_ms: ttl_ms})
       when renew_interval_ms < ttl_ms,
       do: :ok

  defp validate_timing(%__MODULE__{} = backend) do
    {:error,
     Jido.Cluster.Error.validation_error(
       "lease renew_interval_ms must be less than ttl_ms",
       %{details: %{renew_interval_ms: backend.renew_interval_ms, ttl_ms: backend.ttl_ms}}
     )}
  end
end
