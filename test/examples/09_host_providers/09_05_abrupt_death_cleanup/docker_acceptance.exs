defmodule JidoCluster.Examples.AbruptDeathCleanupDockerTest do
  # Real Docker effects require this explicit runner.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.AbruptDeathCleanup
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario
  alias JidoCluster.Test.DockerEngine
  @moduletag cluster_nodes: 1, timeout: 240_000

  setup_all do
    %{docker_options: DockerEngine.preflight!()}
  end

  @tag tmp_dir: true
  test "abrupt owner loss resumes Docker deletion and preserves three independent resources", context do
    Scenario.abrupt_death(
      H.start(context, AbruptDeathCleanup, additional_hosts: [:owned, :borrowed, :owned], faults: true)
    )
  end
end
