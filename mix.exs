defmodule JidoCluster.MixProject do
  use Mix.Project

  @version "3.0.0-dev"
  @source_url "https://github.com/agentjido/jido_cluster"

  def project do
    [
      app: :jido_cluster,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jido Cluster",
      description: "Connected BEAM cluster foundation for Jido V3 agents.",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md", "guides/v3-foundation.md"]],
      dialyzer: [plt_add_apps: [:mix], plt_local_path: "priv/plts/project.plt", plt_core_path: "priv/plts/core.plt"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :mnesia], mod: {JidoCluster.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Local V3 integration. Restore Hex requirements before a package release.
      {:jido, "~> 3.0.0-beta.1", path: "../jido", override: true},
      {:jido_signal, "~> 3.0.0-beta.4", path: "../jido_signal", override: true},
      {:jido_action, "~> 3.0.0-beta.11", path: "../jido_action", override: true},
      {:ex_unit_cluster, "~> 0.7.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      q: ["quality"],
      quality: ["format --check-formatted", "compile --warnings-as-errors", "credo --strict", "doctor --raise"]
    ]
  end
end
