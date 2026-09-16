defmodule JidoCluster.Examples.BorrowedAndIncompatibleTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.BorrowedAndIncompatible
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario

  @tag tmp_dir: true
  test "borrowed capacity remains running after its subscriber stops", context do
    Scenario.borrowed(H.start(context, BorrowedAndIncompatible, ownership: :borrowed))
  end

  @tag tmp_dir: true
  test "a wrong namespace blocks Agent startup and owned cleanup remains available", context do
    Scenario.incompatible(H.start(context, BorrowedAndIncompatible, worker_namespace: "unrelated-namespace"))
  end
end
