defmodule JidoCluster.ActivationTest do
  use ExUnit.Case, async: false
  alias Jido.Cluster
  alias Jido.Cluster.Activation
  alias JidoCluster.Test.WorkerTopology, as: RequirementScheduling
  import JidoCluster.Test.Eventually

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "activation-owner-loss"
  end

  test "cleanup evidence belongs to an exact owner and attempt" do
    scope = {"activation-test", Jido.generate_id()}
    activation = Activation.new(scope, "work")

    owner =
      spawn(fn ->
        receive do
          {:settle, activation, caller} -> send(caller, {:settled, Activation.settle(activation, self())})
        end

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert :ok = Activation.claim(activation, owner)
    assert {:ok, {:active, ^owner}} = Activation.inspect(activation)
    assert {:error, :owner_mismatch} = Activation.settle(activation, self())
    other = Activation.new(scope, "work")
    assert {:error, :cleanup_unconfirmed} = Activation.claim(other, self())
    assert {:error, :owner_mismatch} = Activation.settle(activation, owner)
    send(owner, {:settle, activation, self()})
    assert_receive {:settled, :ok}
    assert {:ok, :settled} = Activation.inspect(activation)
    assert {:error, :activation_closed} = Activation.claim(activation, owner)
    assert :ok = Activation.claim(other, self())
    assert {:error, :activation_changed} = Activation.inspect(activation)
    assert :ok = Activation.settle(other, self())
    assert {:error, :activation_changed} = Activation.claim(activation, self())
  end

  test "closing an unstarted attempt prevents its delayed owner from starting later" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    assert :ok = Activation.unstarted(activation)
    assert {:error, :activation_closed} = Activation.claim(activation, self())
    next = Activation.new({activation.namespace, activation.scope}, activation.topology_id)
    assert next.serial > activation.serial
    assert :ok = Activation.claim(next, self())
    assert :ok = Activation.settle(next, self())
    assert {:error, :activation_changed} = Activation.claim(activation, self())
  end

  test "resource admission closes before cleanup without claiming settlement" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    assert :ok = Activation.claim(activation, self())
    assert :ok = Activation.authorize(activation, self())
    assert {:error, :owner_mismatch} = Activation.authorize(activation, nil)
    caller = self()

    task = Task.async(fn -> Activation.close(activation, caller) end)
    assert {:error, :owner_mismatch} = Task.await(task)
    assert :ok = Activation.authorize(activation, self())
    assert :ok = Activation.close(activation, self())
    assert :ok = Activation.close(activation, self())
    assert {:error, :activation_closed} = Activation.authorize(activation, self())
    assert {:ok, {:active, ^caller}} = Activation.inspect(activation)
    next = Activation.new({activation.namespace, activation.scope}, activation.topology_id)
    assert {:error, :cleanup_unconfirmed} = Activation.claim(next, self())
    assert :ok = Activation.settle(activation, self())
    assert :ok = Activation.close(activation, self())
    assert {:error, :activation_closed} = Activation.authorize(activation, self())
    assert {:ok, :settled} = Activation.inspect(activation)
    assert :ok = Activation.claim(next, self())
    assert :ok = Activation.settle(next, self())
  end

  test "owner death is uncertainty and cannot authorize a replacement" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Activation.claim(activation, owner)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert {:error, :cleanup_unconfirmed} = Activation.cleanup(activation)
    replacement = Activation.new({activation.namespace, activation.scope}, activation.topology_id)
    assert {:error, :cleanup_unconfirmed} = Activation.claim(replacement, self())
  end

  test "resource records retain exact child ownership through repeated deployment claims" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    owner = self()
    assert :ok = Activation.claim(activation, owner)

    resource =
      spawn(fn ->
        send(owner, {:resource_claimed, Activation.claim_resource(activation, owner, "events")})

        receive do
          :settle -> send(owner, {:resource_settled, Activation.settle_resource(activation, owner, "events")})
        end
      end)

    on_exit(fn -> Process.exit(resource, :kill) end)
    assert_receive {:resource_claimed, :ok}
    assert :ok = Activation.claim(activation, owner)
    assert {:ok, {:active, ^resource}} = Activation.resource(activation, owner, node(), "events")
    assert {:error, :owner_mismatch} = Activation.settle_resource(activation, owner, "events")
    assert {:error, :resource_cleanup_unconfirmed} = Activation.claim_resource(activation, owner, "events")
    assert {:error, :resource_cleanup_unconfirmed} = Activation.settle(activation, owner)
    assert :ok = Activation.close(activation, owner)
    assert {:error, :activation_closed} = Activation.claim_resource(activation, owner, "late")
    assert {:ok, :unstarted} = Activation.resource(activation, owner, node(), "late")
    send(resource, :settle)
    assert_receive {:resource_settled, :ok}
    assert :ok = Activation.settle(activation, owner)
  end

  test "missing evidence and another runtime cannot prove cleanup" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    assert {:error, :activation_missing} = Activation.cleanup(activation)
    assert {:error, :runtime_changed} = Activation.inspect(%{activation | runtime: Jido.generate_id()})
    assert {:error, :runtime_changed} = Activation.claim(%{activation | node: "other@host"}, self())
  end

  test "resource revisions advance only from exact settled evidence and reject stale mutations" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    owner = self()
    assert :ok = Activation.claim(activation, owner)
    assert :ok = Activation.claim_resource(activation, owner, "events", 0)
    assert :ok = Activation.authorize_resource(activation, owner, "events", 0)
    assert {:error, :resource_cleanup_unconfirmed} = Activation.prepare_resource(activation, owner, node(), "events", 1)
    task = Task.async(fn -> Activation.close_resource(activation, owner, node(), "events", 0) end)
    assert {:error, :invalid_resource_request} = Task.await(task)
    assert :ok = Activation.close_resource(activation, owner, node(), "events", 0)
    assert {:error, :resource_closed} = Activation.authorize_resource(activation, owner, "events", 0)
    assert {:error, :resource_cleanup_unconfirmed} = Activation.prepare_resource(activation, owner, node(), "events", 1)
    assert :ok = Activation.settle_resource(activation, owner, "events", 0)
    assert {:error, :resource_revision_changed} = Activation.prepare_resource(activation, owner, node(), "events", 2)
    assert :ok = Activation.prepare_resource(activation, owner, node(), "events", 1)
    assert :ok = Activation.prepare_resource(activation, owner, node(), "events", 1)
    assert {:error, :resource_revision_changed} = Activation.claim_resource(activation, owner, "events", 0)
    assert :ok = Activation.claim_resource(activation, owner, "events", 1)
    assert {:error, :resource_revision_changed} = Activation.settle_resource(activation, owner, "events", 0)

    assert {:ok, %{revision: 1, phase: :active, owner: ^owner}} =
             Activation.resource_state(activation, owner, node(), "events")

    assert :ok = Activation.settle_resource(activation, owner, "events", 1)
    assert :ok = Activation.close(activation, owner)
    assert :ok = Activation.settle(activation, owner)
    assert {:error, :activation_closed} = Activation.prepare_resource(activation, owner, node(), "events", 2)
  end

  test "closing an unstarted resource revision fences delayed creation without growing its ledger" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    assert :ok = Activation.claim(activation, self())

    for revision <- 0..10 do
      assert :ok = Activation.close_resource(activation, self(), node(), "events", revision)
      assert {:error, :resource_cleanup_unconfirmed} = Activation.claim_resource(activation, self(), "events", revision)
      assert :ok = Activation.prepare_resource(activation, self(), node(), "events", revision + 1)
    end

    assert {:ok, [{host, "events"}]} = Activation.resources(activation, self())
    assert host == node()

    assert {:ok, %{revision: 11, phase: :unstarted, owner: nil}} =
             Activation.resource_state(activation, self(), node(), "events")

    assert {:error, :invalid_resource_revision} = Activation.prepare_resource(activation, self(), node(), "events", -1)
    assert :ok = Activation.close(activation, self())
    assert :ok = Activation.settle(activation, self())
    assert {:error, :activation_closed} = Activation.claim_resource(activation, self(), "events", 11)
  end

  test "invalid owners and malformed identities do not damage the evidence process" do
    activation = Activation.new({"activation-test", Jido.generate_id()}, "work")
    assert {:error, :invalid_owner} = Activation.claim(activation, nil)
    assert {:error, :invalid_activation} = Activation.inspect(%{})
    assert {:error, :activation_missing} = Activation.inspect(activation)
  end

  test "a missing live directory entry after owner death does not become a receipt" do
    hosts = [%{node: node(), capacity: 1, labels: ["compute"], available: true}]
    start_supervised!({Service, journal: :memory, pools: [workers: [hosts: hosts]]})
    topology = RequirementScheduling.new!(id: "owner-loss")
    {:ok, operation} = Cluster.deploy(Service, topology, request_id: Cluster.request_id(Service))
    {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    {:ok, %{activation: activation}} = Cluster.status(Service, topology.id)
    {:ok, {:active, owner}} = Activation.inspect(activation)
    {:ok, ref} = Cluster.ref(Service, topology.id, :worker)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    eventually(fn -> Jido.resolve_agent(Service.Core, ref) == {:error, :not_found} end)
    assert {:error, :cleanup_unconfirmed} = Activation.cleanup(activation)
    assert [_] = Cluster.claims(Service)
  end
end
