defmodule JidoCluster.Deployment.RuntimeTest do
  use ExUnit.Case, async: false

  alias Jido.Cluster.Deployment
  alias Jido.Topology.Controller
  alias JidoCluster.Test.WorkerTopology

  setup do
    jido = __MODULE__.Core
    start_supervised!({Jido, name: jido})

    options = [
      jido: jido,
      topology: WorkerTopology.new!(id: "scope-owned"),
      hosts: [%{node: node(), labels: ["compute"], capacity: 1, available: true}]
    ]

    %{jido: jido, options: options}
  end

  test "placement cannot start without the scope's reservation and activation guard", c do
    # A host inventory is only input to admission. It does not authorize this
    # private worker to allocate capacity or start a core Controller by itself.
    for extra <- [[], [reservation: %{"worker" => node()}], [guard: %{owner: self(), scope: {"test", "scope"}}]] do
      assert {:error, :deployment_authority_required} = Deployment.start_link(c.options ++ extra)
      assert Controller.whereis(c.jido, "scope-owned") == nil
    end
  end

  test "invalid runtime options fail before any activation", c do
    assert {:error, :invalid_deployment_options} = Deployment.start_link(:invalid)

    for extra <- [[timeout: 0], [poll_interval: -1], [surprise: true]] do
      assert {:error, :invalid_deployment_options} = Deployment.start_link(Keyword.merge(c.options, extra))
    end

    assert Controller.whereis(c.jido, "scope-owned") == nil
  end
end
