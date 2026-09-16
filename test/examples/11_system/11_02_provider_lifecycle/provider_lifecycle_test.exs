defmodule JidoCluster.Examples.ProviderLifecycleTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.ProviderLifecycle
  alias JidoCluster.Examples.Support.{SystemLifecycleCase, SystemLifecycleScenario}

  for mode <- [:attached, :managed] do
    @tag cluster_nodes: 4, tmp_dir: true, timeout: 180_000
    test "#{mode} Core preserves acquired and borrowed hosts through the cumulative lifecycle", context do
      context
      |> SystemLifecycleCase.start(unquote(mode), topology: ProviderLifecycle, providers: true)
      |> SystemLifecycleScenario.run()
    end
  end
end
