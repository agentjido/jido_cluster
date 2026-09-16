defmodule Jido.Cluster.Federation.Gate do
  @moduledoc """
  Fixed admission slots checked in the caller before mailbox submission.

  Each slot reserves the maximum envelope size. The effective count is the lesser
  of the slot limit and the byte budget divided by that size. This can reject
  small envelopes before their actual bytes fill the budget. It avoids a separate
  byte counter that could leak or become inconsistent after caller death.

  The owner creates an ETS table for one bridge generation. Concurrent callers
  reserve slots directly through atomic insert, without calling that bridge.
  A caller submits at most one message for each permit. The bridge releases the
  permit only after all use of that queued payload has ended. A timeout or caller
  exit does not release a permit: its message could still be queued. An abandoned
  permit stays charged until explicit completion or closure of the generation.

  The owner's exit deletes the table. Old handles then reject admission. Permits
  are internal capabilities for trusted runtime code, not peer authentication.
  """

  alias Jido.Cluster.Federation.Limits

  @type t :: %__MODULE__{
          table: :ets.tid(),
          slots: pos_integer(),
          byte_limit: pos_integer(),
          envelope_limit: pos_integer()
        }
  @type permit :: {pos_integer(), reference()}
  @enforce_keys [:table, :slots, :byte_limit, :envelope_limit]
  defstruct [:table, :slots, :byte_limit, :envelope_limit]

  @doc "Creates fixed admission capacity owned by the calling bridge process."
  @spec new(Limits.t(), :inbound | :outbound) :: t()
  def new(%Limits{} = limits, direction) when direction in [:inbound, :outbound] do
    {slots, bytes} =
      case direction do
        :inbound -> {limits.inbound_slots, limits.inbound_bytes}
        :outbound -> {limits.outbound_slots, limits.outbound_bytes}
      end

    %__MODULE__{
      table: :ets.new(__MODULE__, [:set, :public, write_concurrency: true]),
      slots: min(slots, div(bytes, limits.max_envelope_bytes)),
      byte_limit: bytes,
      envelope_limit: limits.max_envelope_bytes
    }
  end

  @doc "Reserves a slot without sending any process a message."
  @spec reserve(t(), pos_integer()) :: {:ok, permit()} | {:error, atom()}
  def reserve(gate, bytes) when is_integer(bytes) and bytes > 0 do
    if bytes > gate.envelope_limit do
      {:error, :envelope_too_large}
    else
      token = make_ref()
      slot = Enum.find(1..gate.slots, &:ets.insert_new(gate.table, {&1, token, bytes}))
      if slot, do: {:ok, {slot, token}}, else: {:error, :capacity}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  def reserve(_, _), do: {:error, :invalid_size}

  @doc "Releases the exact completed permit; an old permit cannot free a reused slot."
  @spec release(t(), permit()) :: :ok | {:error, atom()}
  def release(gate, {slot, token}) when is_integer(slot) and is_reference(token) do
    case :ets.select_delete(gate.table, [{{slot, token, :_}, [], [true]}]) do
      1 -> :ok
      0 -> {:error, :stale_permit}
    end
  rescue
    ArgumentError -> {:error, :closed}
  end

  def release(_, _), do: {:error, :stale_permit}

  @doc "Reports capacity and current use without exposing payloads or caller identities."
  @spec status(t()) :: map() | {:error, :closed}
  def status(gate) do
    entries = :ets.tab2list(gate.table)

    %{
      slot_limit: gate.slots,
      byte_limit: gate.byte_limit,
      used_slots: length(entries),
      reserved_bytes: length(entries) * gate.envelope_limit,
      payload_bytes: Enum.sum(Enum.map(entries, &elem(&1, 2)))
    }
  rescue
    ArgumentError -> {:error, :closed}
  end

  @doc "Closes this generation from its owner; already closed generations stay closed."
  @spec close(t()) :: :ok | {:error, :not_owner}
  def close(gate) do
    case :ets.info(gate.table, :owner) do
      :undefined -> :ok
      owner when owner == self() -> :ets.delete(gate.table) && :ok
      _ -> {:error, :not_owner}
    end
  end
end
