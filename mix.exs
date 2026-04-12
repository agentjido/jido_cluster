defmodule JidoCluster.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_cluster"
  @description "Distributed Jido instance management and storage adapters for multi-node Elixir clusters."

  def project do
    [
      app: :jido_cluster,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),

      # Documentation
      name: "Jido Cluster",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package(),

      # Test coverage
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 90],
        export: "cov",
        ignore_modules: [~r/^JidoClusterTest\./]
      ],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix],
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {JidoCluster.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.lcov": :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Runtime
      jido_dep(),
      bedrock_dep(),
      {:libcluster, "~> 3.5", optional: true},
      {:dns_cluster, "~> 0.2", optional: true},
      {:ecto_sql, "~> 3.13", optional: true},
      {:splode, "~> 0.2"},

      # Test
      {:ex_unit_cluster, "~> 0.7.0", only: :test},
      {:local_cluster, "~> 2.1", only: :test},

      # Dev/Test quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:doctor, "~> 0.21", only: :dev, runtime: false},
      {:spec_led_ex,
       git: "https://github.com/specleddev/specled_ex.git",
       ref: "b5ef58bea18f966bbab247501b738dc260489013",
       only: [:dev, :test],
       runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "git_hooks.install"],
      test: "test --exclude flaky --exclude real_bedrock",
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "spec.check --no-run-commands",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp jido_dep do
    local_dep_or_hex(:jido, "../jido", "~> 2.2")
  end

  defp bedrock_dep do
    local_dep_or_hex(:bedrock, "../bedrock", "~> 0.5", optional: true)
  end

  # Keep the repo standalone by default, but allow explicit sibling checkouts when needed.
  defp local_dep_or_hex(app, relative_path, requirement, opts \\ []) do
    if System.get_env("JIDO_CLUSTER_USE_LOCAL_PATH_DEPS") in ["1", "true"] and
         File.dir?(Path.expand(relative_path, __DIR__)) do
      {app, Keyword.put(opts, :path, relative_path)}
    else
      {app, requirement, opts}
    end
  end

  defp package do
    [
      files: [
        "lib",
        "config",
        "guides",
        ".spec",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "usage-rules.md"
      ],
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_cluster/changelog.html",
        "Discord" => "https://agentjido.xyz/discord",
        "Documentation" => "https://hexdocs.pm/jido_cluster",
        "GitHub" => @source_url,
        "Website" => "https://agentjido.xyz"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/fly-multi-region-failover-demo.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ]
    ]
  end
end
