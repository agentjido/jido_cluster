defmodule Jido.Cluster.Federation.Dedup do
  @moduledoc """
  Bounded duplicate suppression within one channel and bridge generation.

  An identity remains protected until its original monotonic deadline. Repeated
  delivery does not extend that deadline. A full cache rejects new identities;
  it does not evict an unexpired identity and weaken the stated window.

  Admission returns a candidate value. The bridge retains that value only after
  local Bus append succeeds. Discarding it after append failure permits a retry.
  A bridge restart loses this cache; delivery is not globally exactly once.
  """

  alias Jido.Cluster.Federation.Limits

  @type identity :: {String.t(), String.t()}
  @type t :: %__MODULE__{entries: %{identity() => integer()}, limit: pos_integer(), ttl_ms: pos_integer()}
  @enforce_keys [:limit, :ttl_ms]
  defstruct [:limit, :ttl_ms, entries: %{}]

  @doc "Creates an empty cache from validated limits."
  @spec new(Limits.t()) :: t()
  def new(%Limits{} = limits), do: %__MODULE__{limit: limits.dedup_entries, ttl_ms: limits.dedup_ttl_ms}

  @doc "Prunes expired identities, then suppresses, admits, or rejects one export."
  @spec admit(t(), identity(), integer()) :: {:new | :duplicate, t()} | {:error, :dedup_capacity, t()}
  def admit(cache, identity, now) when is_integer(now) do
    entries = Map.reject(cache.entries, fn {_, expires} -> expires <= now end)
    cache = %{cache | entries: entries}

    cond do
      Map.has_key?(entries, identity) -> {:duplicate, cache}
      map_size(entries) >= cache.limit -> {:error, :dedup_capacity, cache}
      true -> {:new, %{cache | entries: Map.put(entries, identity, now + cache.ttl_ms)}}
    end
  end

  @doc "Reports retained identities, including any that expire before the next admission."
  @spec size(t()) :: non_neg_integer()
  def size(cache), do: map_size(cache.entries)
end
