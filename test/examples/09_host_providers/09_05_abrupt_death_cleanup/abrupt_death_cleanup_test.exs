defmodule JidoCluster.Examples.AbruptDeathCleanupTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.AbruptDeathCleanup
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario

  @tag cluster_nodes: 5, tmp_dir: true, timeout: 90_000
  test "abrupt owner loss resumes saved deletion and preserves the other resource identities", context do
    Scenario.abrupt_death(
      H.start(context, AbruptDeathCleanup, additional_hosts: [:owned, :borrowed, :owned], faults: true)
    )
  end
end
