defmodule JidoCluster.StorageCapabilitiesTest do
  use ExUnit.Case, async: true

  alias JidoCluster.StorageCapabilities

  test "marks shared backends correctly" do
    refute StorageCapabilities.shared_backend?({JidoCluster.Storage.ETS, []})
    refute StorageCapabilities.shared_backend?({Jido.Cluster.Storage.ETS, []})
    assert StorageCapabilities.shared_backend?({JidoCluster.Storage.Mnesia, []})
    assert StorageCapabilities.shared_backend?({Jido.Cluster.Storage.Mnesia, []})
    assert StorageCapabilities.shared_backend?({JidoCluster.Storage.Bedrock, []})
    assert StorageCapabilities.shared_backend?({Jido.Cluster.Storage.Bedrock, []})
    assert StorageCapabilities.shared_backend?({JidoCluster.Storage.Postgres, []})
    assert StorageCapabilities.shared_backend?({Jido.Cluster.Storage.Postgres, []})
  end

  test "falls back to opts[:shared] for unknown adapters" do
    refute StorageCapabilities.shared_backend?({My.Unknown.Storage, []})
    assert StorageCapabilities.shared_backend?({My.Unknown.Storage, [shared: true]})
  end
end
