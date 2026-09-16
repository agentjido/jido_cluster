defmodule JidoCluster.Federation.DeploymentTest do
  use ExUnit.Case, async: false
  import JidoCluster.Test.Eventually
  alias Jido.Cluster
  alias Jido.Cluster.Federation.{Limits, Mirror, Runtime}
  alias Jido.Signal.Bus
  alias Jido.Topology.Controller
  alias JidoCluster.Test.Federation.DeclaredTopology

  defmodule Service do
    use Jido.Cluster, otp_app: :jido_cluster, namespace: "declared-federation"
  end

  setup do
    hosts = [%{node: node(), labels: ["compute"], capacity: 2, available: true}]
    start_supervised!({Service, journal: :memory, federation: [outbound_slots: 1], pools: [workers: [hosts: hosts]]})
    {:ok, config} = Cluster.config(Service)
    %{config: config, topology: DeclaredTopology.new!(id: "declared")}
  end

  test "declaration deployment confirms attachment, preserves Signals, and settles all resources", c do
    assert {:ok, %{placements: %{"listener" => host}}} = Cluster.plan(Service, c.topology)
    assert host == node()
    assert Controller.whereis(c.config.jido, c.topology.id) == nil
    assert {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:ok, completed} = Cluster.await(Service, operation.id)
    assert completed.phase == :completed

    assert {:ok, %{agent_readiness: :ready, binding_readiness: :ready, federation_health: :healthy} = status} =
             Cluster.status(Service, c.topology.id)

    assert {:ok, %{channels: [channel], health: :healthy}} = Cluster.federation_status(Service, c.topology.id)
    assert channel.scope == {c.config.namespace, c.topology.id, "events"}
    assert channel.interested_hosts == [node()]
    assert [%{bindings: [%{ready: true, subscription_count: 1}], configured: true}] = channel.hosts
    {:ok, ref} = Cluster.ref(Service, c.topology.id, :listener)
    {:ok, %{pid: agent}} = Cluster.lookup(Service, ref)
    signal = Jido.Signal.new!(%{id: "original", type: "counter.changed", source: "/test", data: %{bytes: <<255>>}})
    assert {:error, :channel_not_found} = Cluster.publish(Service, c.topology.id, :absent, signal)
    assert {:error, _} = Cluster.publish(Service, c.topology.id, :events, %{signal | type: "counter.other"})
    assert {:ok, %{local: :accepted, targets: []}} = Cluster.publish(Service, c.topology.id, :events, signal)
    eventually(fn -> Jido.AgentServer.snapshot(agent).state_version == 1 end)
    assert Jido.AgentServer.snapshot(agent).agent.state.events == [Map.take(signal, [:id, :type, :source, :data])]
    assert {:ok, ^completed} = Cluster.operation(Service, operation.id)
    {:ok, mirror} = Mirror.lookup(c.config.jido, status.activation, "events")
    children = Mirror.status(mirror).components
    assert {:ok, stop} = Cluster.stop(Service, c.topology.id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, stop.id)
    for pid <- [agent, mirror | Map.values(children)], do: refute(Process.alive?(pid))
    assert [] = Cluster.claims(Service)
    assert {:error, :stopped} = Cluster.publish(Service, c.topology.id, :events, signal)
    assert {:ok, %{binding_readiness: :stopped, federation_health: :stopped}} = Cluster.status(Service, c.topology.id)
  end

  test "federation limits and ownership are validated before effects", c do
    assert {:error, :invalid_federation_limits} = Service.config(journal: :memory, federation: [outbound_slots: 0])
    {:ok, limits} = Limits.new(max_hosts: 1)

    assert {:error, :federation_host_limit} =
             Runtime.plan(c.topology, c.config.namespace, %{"listener" => :other@host}, node(), limits)

    assert {:error, :deployment_authority_required} =
             Cluster.Deployment.start_link(
               jido: c.config.jido,
               topology: c.topology,
               hosts: c.config.hosts
             )

    assert Controller.whereis(c.config.jido, c.topology.id) == nil
    assert [] = Cluster.claims(Service)
  end

  test "initial completion waits for the required attachment receipt", c do
    handler = hold([:jido, :signal, :bus, :subscription, :attached])
    assert {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert_receive {:bus_waiting, bus}, 2000
    on_exit(fn -> send(bus, :continue_bus) end)
    assert {:ok, %{phase: :accepted}} = Cluster.operation(Service, operation.id)
    assert {:ok, %{agent_readiness: :ready, binding_readiness: readiness}} = Cluster.status(Service, c.topology.id)
    refute readiness == :ready
    signal = Jido.Signal.new!(%{type: "counter.changed", source: "/test", data: %{}})
    assert {:error, :not_ready} = Cluster.publish(Service, c.topology.id, :events, signal)
    :ok = :telemetry.detach(handler)
    send(bus, :continue_bus)
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert {:ok, %{binding_readiness: :ready}} = Cluster.status(Service, c.topology.id)
    stop(c.topology.id)
  end

  test "loss during required attachment cannot complete the deployment", c do
    handler = hold([:jido, :signal, :bus, :subscription, :attached])
    assert {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert_receive {:bus_waiting, bus}, 2000
    :ok = :telemetry.detach(handler)
    monitor = Process.monitor(bus)
    Process.exit(bus, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^bus, :killed}
    assert {:ok, %{phase: :uncertain}} = Cluster.await(Service, operation.id)
    assert {:ok, %{agent_readiness: :ready, binding_readiness: readiness}} = Cluster.status(Service, c.topology.id)
    refute readiness == :ready
    stop(c.topology.id)
  end

  test "concurrent callers reject a full gate while local append is held", c do
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    handler = hold([:jido, :signal, :bus, :publish])
    signal = Jido.Signal.new!(%{id: "admitted", type: "counter.changed", source: "/test", data: %{}})
    first = Task.async(fn -> Cluster.publish(Service, c.topology.id, :events, signal) end)
    assert_receive {:bus_waiting, bus}, 2000
    on_exit(fn -> send(bus, :continue_bus) end)

    tasks =
      for number <- 1..16 do
        Task.async(fn -> Cluster.publish(Service, c.topology.id, :events, %{signal | id: "rejected-#{number}"}) end)
      end

    for task <- tasks, do: assert({:error, :capacity} = Task.await(task, 2000))
    :ok = :telemetry.detach(handler)
    send(bus, :continue_bus)
    assert {:ok, %{local: :accepted}} = Task.await(first)
    assert {:ok, [record]} = Bus.replay(bus, "counter.changed")
    assert record.signal == signal
    stop(c.topology.id)
  end

  test "lost required bindings change current readiness without rewriting completion", c do
    {:ok, operation} = Cluster.deploy(Service, c.topology, request_id: Cluster.request_id(Service))
    assert {:ok, completed} = Cluster.await(Service, operation.id)
    assert completed.phase == :completed
    {:ok, %{activation: activation}} = Cluster.status(Service, c.topology.id)
    {:ok, mirror} = Mirror.lookup(c.config.jido, activation, "events")
    receiver = Mirror.status(mirror).components.receiver
    monitor = Process.monitor(mirror)
    Process.exit(receiver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^mirror, :normal}, 5000
    assert {:ok, %{agent_readiness: :ready, binding_readiness: readiness}} = Cluster.status(Service, c.topology.id)
    refute readiness == :ready
    assert {:ok, ^completed} = Cluster.operation(Service, operation.id)
    stop(c.topology.id)
  end

  def hold_bus(_, _, %{bus_name: "cluster-channel:" <> _}, observer) do
    send(observer, {:bus_waiting, self()})

    receive do
      :continue_bus -> :ok
    after
      5000 -> raise "Bus barrier timed out"
    end
  end

  def hold_bus(_, _, _, _), do: :ok

  defp hold(event) do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, event, &__MODULE__.hold_bus/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp stop(id) do
    assert {:ok, operation} = Cluster.stop(Service, id, request_id: Cluster.request_id(Service))
    assert {:ok, %{phase: :completed}} = Cluster.await(Service, operation.id)
    assert [] = Cluster.claims(Service)
  end
end
