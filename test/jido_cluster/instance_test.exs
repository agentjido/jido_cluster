defmodule JidoCluster.InstanceTest do
  use ExUnit.Case, async: false

  defmodule Managed do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "instance-contract"
  end

  defmodule Attached do
    use Jido.Cluster, otp_app: :jido_cluster, jido: JidoCluster.InstanceTest.Core
  end

  test "module, application, and start configuration have explicit precedence" do
    Application.put_env(:jido_cluster, Managed, namespace: "application", journal: :memory)
    on_exit(fn -> Application.delete_env(:jido_cluster, Managed) end)

    assert {:ok, config} = Managed.config(namespace: "override")
    assert config.namespace == "override"
    assert config.jido == Module.concat(Managed, Core)
    assert config.mode == :managed
    assert config.scope == "default"
    assert config.journal == :memory
    assert config.agent_persistence == nil
    assert {:error, :invalid_instance_options} = Managed.config(surprise: true)
  end

  test "managed core has a stable name and stops with its owner" do
    cluster = start_supervised!({Managed, journal: :memory})
    assert {:ok, config} = Jido.Cluster.config(Managed)
    core = Process.whereis(config.jido)
    assert is_pid(core)
    assert Jido.namespace(config.jido) == "instance-contract"
    assert %{durability: :memory_only, mode: :managed} = Jido.Cluster.status(Managed)
    assert :ok = stop_supervised(Managed)
    refute Process.alive?(cluster)
    refute Process.alive?(core)
  end

  test "attached mode inherits namespace and retains application core" do
    core = start_supervised!({Jido, name: __MODULE__.Core, namespace: "attached-contract"})
    start_supervised!({Attached, journal: :memory})
    assert {:ok, %{mode: :attached, namespace: "attached-contract"}} = Jido.Cluster.config(Attached)
    assert :ok = stop_supervised(Attached)
    assert Process.alive?(core)
    assert Jido.namespace(__MODULE__.Core) == "attached-contract"
    assert {:error, :namespace_conflict} = Attached.start_link(journal: :memory, namespace: "wrong")
    assert Process.alive?(core)
  end

  test "missing attached core and missing Bedrock configuration fail before startup" do
    assert {:error, :jido_not_started} = Attached.start_link(journal: :memory)
    assert {:error, {:invalid_journal, _}} = Managed.start_link([])
    refute Process.whereis(Managed)
    refute Process.whereis(Module.concat(Managed, Core))
  end

  test "a managed name collision cannot silently change ownership mode" do
    name = Module.concat(Managed, Core)
    core = start_supervised!({Jido, name: name, namespace: "collision"})
    assert {:error, :managed_core_already_started} = Managed.start_link(journal: :memory)
    assert Process.alive?(core)
  end
end
