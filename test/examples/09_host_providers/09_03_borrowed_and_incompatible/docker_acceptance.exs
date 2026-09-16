defmodule JidoCluster.Examples.BorrowedAndIncompatibleDockerTest do
  # Real Docker effects require this explicit runner.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.BorrowedAndIncompatible
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario
  alias JidoCluster.Test.DockerEngine
  @moduletag cluster_nodes: 1, timeout: 180_000

  setup_all do
    %{docker_options: DockerEngine.preflight!()}
  end

  @tag tmp_dir: true
  test "borrowed Docker capacity remains running after scope release", context do
    Scenario.borrowed(H.start(context, BorrowedAndIncompatible, ownership: :borrowed))
  end

  @tag tmp_dir: true
  test "an incompatible Docker worker starts no Agent and remains available for owned cleanup", context do
    Scenario.incompatible(H.start(context, BorrowedAndIncompatible, worker_namespace: "unrelated-namespace"))
  end
end
