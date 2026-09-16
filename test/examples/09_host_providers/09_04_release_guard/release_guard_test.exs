defmodule JidoCluster.Examples.ReleaseGuardTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.ReleaseGuard
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario

  @tag tmp_dir: true
  test "a live partition holds required binding cleanup and prevents host deletion", context do
    Scenario.release_guard(H.start(context, ReleaseGuard))
  end

  @tag tmp_dir: true
  test "a stale resource handle cannot delete a replacement incarnation", context do
    Scenario.stale_resource(H.start(context, ReleaseGuard))
  end
end
