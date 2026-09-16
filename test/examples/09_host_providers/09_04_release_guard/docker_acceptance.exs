defmodule JidoCluster.Examples.ReleaseGuardDockerTest do
  # Real Docker effects require this explicit runner.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.ReleaseGuard
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario
  alias JidoCluster.Test.DockerEngine
  @moduletag cluster_nodes: 1, timeout: 180_000

  setup_all do
    %{docker_options: DockerEngine.preflight!()}
  end

  @tag tmp_dir: true
  test "required binding cleanup prevents Docker deletion during a live partition", context do
    Scenario.release_guard(H.start(context, ReleaseGuard))
  end

  @tag tmp_dir: true
  test "an old Docker handle cannot delete an actual replacement container", context do
    Scenario.stale_resource(H.start(context, ReleaseGuard))
  end
end
