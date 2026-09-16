defmodule JidoCluster.Examples.AcquiredTopologyDockerTest do
  # Real Docker effects require this explicit runner.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.AcquiredTopology
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario
  alias JidoCluster.Test.DockerEngine
  @moduletag cluster_nodes: 1, timeout: 180_000

  setup_all do
    %{docker_options: DockerEngine.preflight!()}
  end

  @tag tmp_dir: true
  test "the same acquired scenario uses actual Docker resources", context do
    Scenario.acquired(H.start(context, AcquiredTopology))
  end
end
