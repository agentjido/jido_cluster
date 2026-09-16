defmodule Jido.Cluster.Federation.Limits do
  @moduledoc """
  Validated capacity limits for one host-local channel mirror.

  Defaults reserve at most 32 envelopes and 512 KiB in each direction. A single
  envelope is at most 16 KiB. At most 32 hosts can participate in a channel.
  The duplicate cache retains at most 1024 identities for at most 60 seconds.
  Queue bytes include the entire uncompressed external-term envelope. They do not
  include VM object headers or caller-owned Signal values.

  These are infrastructure budgets. Agent mailboxes and ordinary local Bus
  publishers remain outside federation admission. Validation alone does not
  enforce a queue bound; a transport must use the admitted slots.
  """

  @defaults [
    max_envelope_bytes: 16_384,
    outbound_slots: 32,
    inbound_slots: 32,
    outbound_bytes: 524_288,
    inbound_bytes: 524_288,
    max_hosts: 32,
    dedup_entries: 1024,
    dedup_ttl_ms: 60_000
  ]
  @ceilings %{
    max_envelope_bytes: 65_536,
    outbound_slots: 256,
    inbound_slots: 256,
    outbound_bytes: 16_777_216,
    inbound_bytes: 16_777_216,
    max_hosts: 32,
    dedup_entries: 16_384,
    dedup_ttl_ms: 600_000
  }

  @type t :: %__MODULE__{
          max_envelope_bytes: pos_integer(),
          outbound_slots: pos_integer(),
          inbound_slots: pos_integer(),
          outbound_bytes: pos_integer(),
          inbound_bytes: pos_integer(),
          max_hosts: pos_integer(),
          dedup_entries: pos_integer(),
          dedup_ttl_ms: pos_integer()
        }
  defstruct @defaults

  @doc "Applies explicit overrides and rejects unknown, duplicate, or unbounded values."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_federation_limits}
  def new(options) when is_list(options) do
    if Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
         Enum.all?(options, &valid_option?/1) do
      limits = struct!(__MODULE__, options)

      if min(limits.outbound_bytes, limits.inbound_bytes) >= limits.max_envelope_bytes,
        do: {:ok, limits},
        else: {:error, :invalid_federation_limits}
    else
      {:error, :invalid_federation_limits}
    end
  end

  def new(_), do: {:error, :invalid_federation_limits}

  defp valid_option?({key, value}) do
    case Map.fetch(@ceilings, key) do
      {:ok, ceiling} -> is_integer(value) and value in 1..ceiling
      :error -> false
    end
  end
end
