defmodule JidoCluster.Federation.DedupTest do
  use ExUnit.Case, async: true

  alias Jido.Cluster.Federation.{Dedup, Limits}

  test "duplicate identity is suppressed until its original retention deadline" do
    {:ok, limits} = Limits.new(dedup_ttl_ms: 100)
    cache = Dedup.new(limits)
    assert {:new, cache} = Dedup.admit(cache, {"origin", "export"}, 0)
    assert {:duplicate, cache} = Dedup.admit(cache, {"origin", "export"}, 99)
    assert {:new, cache} = Dedup.admit(cache, {"origin", "export"}, 100)
    assert Dedup.size(cache) == 1
  end

  test "cache saturation rejects a new identity without evicting protected exports" do
    {:ok, limits} = Limits.new(dedup_entries: 2, dedup_ttl_ms: 100)
    cache = Dedup.new(limits)
    assert {:new, cache} = Dedup.admit(cache, {"one", "export"}, 0)
    assert {:new, cache} = Dedup.admit(cache, {"two", "export"}, 1)
    assert {:error, :dedup_capacity, cache} = Dedup.admit(cache, {"three", "export"}, 99)
    assert Dedup.size(cache) == 2
    assert {:duplicate, cache} = Dedup.admit(cache, {"one", "export"}, 99)
    assert {:new, cache} = Dedup.admit(cache, {"three", "export"}, 100)
    assert Dedup.size(cache) == 2
    assert {:duplicate, _} = Dedup.admit(cache, {"two", "export"}, 100)
  end

  test "discarding a candidate after local append failure leaves the export retryable" do
    {:ok, limits} = Limits.new([])
    cache = Dedup.new(limits)
    assert {:new, _candidate} = Dedup.admit(cache, {"one", "export"}, 0)
    assert {:new, _candidate} = Dedup.admit(cache, {"one", "export"}, 1)
    assert Dedup.size(cache) == 0
  end
end
