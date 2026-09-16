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
      test_ignore_filters: [
        "test/fixtures/docker_host/mix.exs",
        "test/jido_cluster/distributed/docker_acceptance.exs",
        "test/examples/09_host_providers/09_01_acquired_topology/docker_acceptance.exs",
        "test/examples/09_host_providers/09_02_lost_acquire_reply/docker_acceptance.exs",
        "test/examples/09_host_providers/09_03_borrowed_and_incompatible/docker_acceptance.exs",
        "test/examples/09_host_providers/09_04_release_guard/docker_acceptance.exs",
        "test/examples/09_host_providers/09_05_abrupt_death_cleanup/docker_acceptance.exs",
        "test/examples/11_system/11_02_provider_lifecycle/docker_acceptance.exs"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jido Cluster",
      description: "Connected BEAM cluster foundation for Jido V3 agents.",
      source_url: @source_url,
      docs: [
        main: "readme",
        extras: [
          {"README.md", filename: "readme"},
          {"guides/README.md", filename: "guides"},
          "guides/named-deployments.md",
          "guides/recovery.md",
          "guides/federated-signals.md",
          "guides/host-providers.md",
          "guides/entities.md",
          "guides/testing.md"
        ],
        groups_for_extras: [Guides: ~r{^guides/}],
        groups_for_modules: [
          "Public API": [
            Jido.Cluster,
            Jido.Cluster.Entity,
            Jido.Cluster.Entity.Identity,
            Jido.Cluster.HostProvider,
            Jido.Cluster.HostProvider.Docker,
            Jido.Cluster.HostProvider.Resource,
            Jido.Cluster.HostProvider.Step,
            Jido.Cluster.HostRuntime,
            Jido.Cluster.Placement,
            Jido.Cluster.Topology.Extension
          ],
          "Runtime internals": ~r{^Jido\.Cluster\.}
        ],
        filter_modules: fn module, _ ->
          not String.starts_with?(Atom.to_string(module), "Elixir.Jido.Cluster.Examples.")
        end
      ],
      dialyzer: [plt_add_apps: [:mix], plt_local_path: "priv/plts/project.plt", plt_core_path: "priv/plts/core.plt"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :mnesia], mod: {JidoCluster.Application, []}]
  end

  def cli do
    [
      preferred_envs: [
        examples: :test,
        "test.examples": :test,
        "test.peer": :test,
        "test.all": :test,
        "test.docker": :test,
        "test.examples.docker": :test
      ]
    ]
  end

  defp elixirc_paths(:test),
    do: ["lib", "examples", "test/support", "test/examples/support", "test/fixtures/docker_host/lib"]

  defp elixirc_paths(:dev), do: ["lib", "examples"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Local V3 integration. Restore Hex requirements before a package release.
      {:jido, "~> 3.0.0-beta.1", path: "../jido", override: true},
      {:jido_signal, "~> 3.0.0-beta.4", path: "../jido_signal", override: true},
      {:jido_action, "~> 3.0.0-beta.11", path: "../jido_action", override: true},
      {:spark, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.7", optional: true},
      {:bedrock, "~> 0.7.2", optional: true},
      {:bedrock_raft, "~> 0.10.0", optional: true},
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
      examples: ["test.examples"],
      "test.examples": "test test/examples --only example --seed 0",
      "test.peer": "test test/jido_cluster/distributed --only peer --seed 0",
      "test.all": "test --include peer --include example --seed 0",
      "test.docker": "test test/jido_cluster/distributed/docker_acceptance.exs --only peer --seed 0",
      "test.examples.docker":
        "test test/examples/09_host_providers/09_01_acquired_topology/docker_acceptance.exs " <>
          "test/examples/09_host_providers/09_02_lost_acquire_reply/docker_acceptance.exs " <>
          "test/examples/09_host_providers/09_03_borrowed_and_incompatible/docker_acceptance.exs " <>
          "test/examples/09_host_providers/09_04_release_guard/docker_acceptance.exs " <>
          "test/examples/09_host_providers/09_05_abrupt_death_cleanup/docker_acceptance.exs " <>
          "test/examples/11_system/11_02_provider_lifecycle/docker_acceptance.exs --only example --seed 0",
      q: ["quality"],
      quality: ["format --check-formatted", "compile --warnings-as-errors", "credo --strict", "doctor --raise"]
    ]
  end
end
