defmodule JidoCluster.Examples.DeploymentLifecycleTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias JidoCluster.Examples.Support.{SystemLifecycleCase, SystemLifecycleScenario}

  for mode <- [:attached, :managed] do
    @tag cluster_nodes: 4, tmp_dir: true, timeout: 180_000
    test "#{mode} Core preserves the cumulative lifecycle through interruption and uncertainty", context do
      context
      |> SystemLifecycleCase.start(unquote(mode))
      |> SystemLifecycleScenario.run()
    end
  end
end
