defmodule JidoClusterDockerHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_cluster_docker_host,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [jido_cluster_docker_host: [include_executables_for: [:unix]]]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {JidoCluster.Test.DockerHost.Application, []}]

  defp deps do
    root = System.get_env("JIDO_SDK_ROOT", Path.expand("../../../..", __DIR__))

    for package <- [:jido_cluster, :jido, :jido_signal, :jido_action],
        do: {package, path: Path.join(root, Atom.to_string(package)), override: true}
  end
end
