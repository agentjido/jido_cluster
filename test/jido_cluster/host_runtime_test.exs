defmodule JidoCluster.HostRuntimeTest do
  use ExUnit.Case, async: false
  alias Jido.Agent.Ref
  alias Jido.Cluster.HostRuntime
  import JidoCluster.Test.Eventually

  setup do
    jido = __MODULE__.Core
    start_supervised!({Jido, name: jido, namespace: "host-contract"})
    host = start_supervised!({HostRuntime, jido: jido, id: "worker-1", release: "test-release"})
    %{host: host, jido: jido}
  end

  test "bounded direct probe reports runtime identity and rejects incompatible registration", %{host: host} do
    assert {:ok, info} = HostRuntime.probe(host, namespace: "host-contract", protocol: 1)
    assert info.id == "worker-1"
    assert info.release == "test-release"
    assert info.node == node()
    assert is_binary(info.incarnation)
    assert {:error, {:incompatible, :namespace}} = HostRuntime.probe(host, namespace: "other", protocol: 1)
    assert {:error, {:incompatible, :protocol}} = HostRuntime.probe(host, namespace: "host-contract", protocol: 2)
    assert {:error, {:missing_module, MissingAgent}} = HostRuntime.probe(host, modules: [MissingAgent])
  end

  test "restart changes incarnation and stale registration is rejected", %{host: host, jido: jido} do
    {:ok, before} = HostRuntime.probe(host, [])
    stop_supervised!(HostRuntime)
    next = start_supervised!({HostRuntime, jido: jido, id: "worker-1", release: "test-release"})
    {:ok, after_restart} = HostRuntime.probe(next, [])
    refute before.incarnation == after_restart.incarnation
    assert {:error, :stale_incarnation} = HostRuntime.register(next, self(), "scope", before.incarnation)

    assert {:error, :reconciliation_required} =
             HostRuntime.register(next, self(), "scope", after_restart.incarnation)
  end

  test "guard death retains claims and capacity until exact reconciliation", %{host: host, jido: jido} do
    {:ok, info} = HostRuntime.probe(host, [])
    :ok = HostRuntime.register(host, self(), "scope", info.incarnation)
    {:ok, ref} = Jido.agent_ref(jido, "guard-restart")
    {:ok, agent} = Jido.start_agent_ref(jido, ref, JidoCluster.Test.PlacementWorker)
    claim = %{id: "retained", scope: "scope", host_incarnation: info.incarnation, operation_id: "op", ref: ref}
    :ok = HostRuntime.confirm(host, self(), "scope", info.incarnation, 1, [claim])

    monitor = Process.monitor(host)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^host, :killed}
    eventually(fn -> is_pid(Process.whereis(HostRuntime.name(jido))) end)
    next = HostRuntime.name(jido)
    {:ok, current} = HostRuntime.probe(next, [])
    assert current.incarnation != info.incarnation
    assert %{control: :reconcile, scope: "scope", claims: [^claim], capacity: 1} = HostRuntime.status(next)
    assert Process.alive?(agent)
    assert {:error, :reconciliation_required} = HostRuntime.register(next, self(), "scope", current.incarnation)
    assert {:error, :claim_mismatch} = HostRuntime.reconcile(next, self(), "scope", current.incarnation, [])

    assert {:error, :scope_already_owned} =
             HostRuntime.reconcile(next, self(), "other", current.incarnation, [claim])

    assert :ok = HostRuntime.reconcile(next, self(), "scope", current.incarnation, [claim])

    assert {:error, :capacity_conflict} =
             HostRuntime.confirm(next, self(), "scope", current.incarnation, 2, [])

    assert {:error, :activation_still_present} =
             HostRuntime.release(next, self(), "scope", current.incarnation, [claim.id], :confirmed)

    :ok = Jido.stop_agent_ref(jido, ref)
    assert :ok = HostRuntime.release(next, self(), "scope", current.incarnation, [claim.id], :confirmed)
    assert %{claims: []} = HostRuntime.status(next)
  end

  test "a new core lifetime does not inherit a former core claim record", %{host: host, jido: jido} do
    {:ok, info} = HostRuntime.probe(host, [])
    :ok = HostRuntime.register(host, self(), "old-scope", info.incarnation)
    stop_supervised!(HostRuntime)
    stop_supervised!(jido)
    start_supervised!({Jido, name: jido, namespace: "host-contract"})
    next = start_supervised!({HostRuntime, jido: jido})
    assert %{control: :unregistered, claims: [], scope: nil} = HostRuntime.status(next)
  end

  test "control loss closes the guard until explicit reconciliation", %{host: host} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    {:ok, info} = HostRuntime.probe(host, [])
    assert :ok = HostRuntime.register(host, owner, "scope", info.incarnation)
    assert %{control: :ready} = HostRuntime.status(host)
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    eventually(fn -> HostRuntime.status(host).control == :reconcile end)
    assert {:error, :reconciliation_required} = HostRuntime.register(host, self(), "scope", info.incarnation)
    assert :ok = HostRuntime.reconcile(host, self(), "scope", info.incarnation, [])
    assert %{control: :ready} = HostRuntime.status(host)
  end

  test "claim confirmation validates incarnation, scope, and stable capacity", %{host: host} do
    {:ok, info} = HostRuntime.probe(host, [])
    assert :ok = HostRuntime.register(host, self(), "scope", info.incarnation)

    claim = %{
      id: "first",
      scope: "scope",
      host_incarnation: info.incarnation,
      operation_id: "op",
      ref: Ref.new!(namespace: "host-contract", id: "agent")
    }

    assert :ok = HostRuntime.confirm(host, self(), "scope", info.incarnation, 1, [claim])
    assert :ok = HostRuntime.confirm(host, self(), "scope", info.incarnation, 1, [claim])

    assert {:error, :no_capacity} =
             HostRuntime.confirm(host, self(), "scope", info.incarnation, 1, [%{claim | id: "second"}])

    assert {:error, :capacity_conflict} = HostRuntime.confirm(host, self(), "scope", info.incarnation, 2, [claim])
    assert {:error, :stale_incarnation} = HostRuntime.confirm(host, self(), "scope", "old", 1, [claim])
    assert {:error, :scope_already_owned} = HostRuntime.confirm(host, self(), "other", info.incarnation, 1, [claim])

    assert {:error, :unconfirmed_cleanup} =
             HostRuntime.release(host, self(), "scope", info.incarnation, ["first"], :timeout)

    assert :ok = HostRuntime.release(host, self(), "scope", info.incarnation, ["first"], :confirmed)
    assert %{claims: []} = HostRuntime.status(host)
  end

  test "a live activation prevents release even if the caller reports cleanup", %{host: host, jido: jido} do
    {:ok, info} = HostRuntime.probe(host, [])
    :ok = HostRuntime.register(host, self(), "scope", info.incarnation)
    {:ok, ref} = Jido.agent_ref(jido, "live")
    {:ok, agent} = Jido.start_agent_ref(jido, ref, JidoCluster.Test.PlacementWorker)
    claim = %{id: "live", scope: "scope", host_incarnation: info.incarnation, operation_id: "op", ref: ref}
    :ok = HostRuntime.confirm(host, self(), "scope", info.incarnation, 1, [claim])

    assert {:error, :activation_still_present} =
             HostRuntime.release(host, self(), "scope", info.incarnation, ["live"], :confirmed)

    assert Process.alive?(agent)
    :ok = Jido.stop_agent_ref(jido, ref)
    assert :ok = HostRuntime.release(host, self(), "scope", info.incarnation, ["live"], :confirmed)
  end
end
