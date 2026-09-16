defmodule JidoCluster.Examples.ProviderLifecycleDockerTest do
  # Real Docker effects require this explicit runner.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.ProviderLifecycle
  alias JidoCluster.Examples.Support.{SystemLifecycleCase, SystemLifecycleScenario}
  alias JidoCluster.Test.DockerEngine
  @moduletag cluster_nodes: 1, timeout: 360_000

  setup_all do
    %{docker_options: DockerEngine.preflight!()}
  end

  for mode <- [:attached, :managed] do
    @tag tmp_dir: true
    @tag docker_core_mode: mode
    test "#{mode} Core retains borrowed Docker capacity through cumulative recovery", context do
      context
      |> SystemLifecycleCase.start(unquote(mode), topology: ProviderLifecycle, providers: true)
      |> SystemLifecycleScenario.run()
    end
  end
end
