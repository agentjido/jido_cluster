defmodule JidoCluster.Examples.AcquiredTopologyTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.AcquiredTopology
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario

  @tag tmp_dir: true
  test "acquire admits a host and release waits for its subscriber and claims", context do
    Scenario.acquired(H.start(context, AcquiredTopology))
  end
end
