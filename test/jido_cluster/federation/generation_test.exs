defmodule JidoCluster.Federation.GenerationTest do
  use ExUnit.Case, async: false
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Binding, Bridge, Gate, Limits, Mirror}
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.{RecordingTransport, Subscriber}

  setup do
    jido = __MODULE__.Core
    start_supervised!({Jido, name: jido, namespace: "generation-test"})
    activation = Activation.new({"generation-test", Jido.generate_id()}, "work")
    :ok = Activation.claim(activation, self())
    {:ok, ref} = Jido.agent_ref(jido, "subscriber")
    {:ok, agent} = Jido.start_agent_ref(jido, ref, Subscriber)
    {:ok, limits} = Limits.new([])

    opts = [
      jido: jido,
      activation: activation,
      owner: self(),
      channel: "events",
      types: ["counter.changed"],
      limits: limits,
      allowed_nodes: [node()],
      bindings: [%{ref: ref, required: true}]
    ]

    {:ok, mirror} = Mirror.ensure(opts)
    :ok = Mirror.attach(mirror, ref, agent)
    :ok = Mirror.connect(mirror, [])
    components = watch(mirror)
    %{jido: jido, activation: activation, ref: ref, agent: agent, opts: opts, mirror: mirror, components: components}
  end

  test "uncertain detach blocks replacement until exact cleanup, then the same Agent gets a new binding", c do
    {:ok, old_publisher} = Mirror.publisher(c.mirror)
    old_binding = hd(Mirror.status(c.mirror).bindings)
    handler = {__MODULE__, make_ref()}
    bus_name = "cluster-channel:" <> c.activation.id <> ":events"
    :ok = :telemetry.attach(handler, [:jido, :signal, :bus, :publish], &__MODULE__.hold_bus/4, {bus_name, self()})

    on_exit(fn ->
      :telemetry.detach(handler)
      send(c.components.bus, :continue_bus)
    end)

    original = signal("before")

    publication =
      Task.async(fn ->
        try do
          Bus.publish(c.components.bus, [original])
        catch
          :exit, _ -> {:error, :publication_uncertain}
        end
      end)

    assert_receive {:bus_waiting, bus}, 2000
    assert bus == c.components.bus
    assert {:error, :detach_uncertain} = Binding.detach(c.components[{:binding, c.ref}], 10)
    assert :ok = Activation.close_resource(c.activation, self(), node(), "events", 0)
    assert {:error, :resource_closed} = Mirror.attach(c.mirror, c.ref, c.agent)
    assert {:error, :resource_closed} = Mirror.publisher(c.mirror)
    owner = self()

    assert {:error, :resource_cleanup_unconfirmed} =
             Activation.prepare_resource(c.activation, self(), node(), "events", 1)

    assert {:ok, %{revision: 0, phase: :closing, owner: mirror}} =
             Activation.resource_state(c.activation, self(), node(), "events")

    assert mirror == c.mirror
    cleanup = Task.async(fn -> Mirror.stop_generation(c.jido, c.activation, owner, "events", 0) end)
    :ok = :telemetry.detach(handler)
    send(bus, :continue_bus)
    result = Task.await(publication)
    assert match?({:ok, [_]}, result) or result == {:error, :publication_uncertain}
    assert :ok = Task.await(cleanup)
    assert {:error, :closed} = Gate.status(old_publisher.gate)
    assert {:ok, current_agent} = Jido.resolve_agent(c.jido, c.ref)
    assert current_agent == c.agent

    assert :ok = Activation.prepare_resource(c.activation, self(), node(), "events", 1)
    assert :ok = Activation.prepare_resource(c.activation, self(), node(), "events", 1)
    assert {:error, :resource_revision_changed} = Mirror.ensure(c.opts)
    {:ok, next} = Mirror.ensure(Keyword.put(c.opts, :revision, 1))
    watch(next)
    assert :ok = Mirror.attach(next, c.ref, c.agent)
    assert :ok = Mirror.connect(next, [])
    assert %{revision: 1, binding_readiness: :ready, bindings: [new_binding]} = Mirror.status(next)
    assert new_binding.id == old_binding.id
    refute new_binding.subscriptions == old_binding.subscriptions
    assert {:error, :resource_revision_changed} = Mirror.stop_generation(c.jido, c.activation, self(), "events", 0)
    assert {:error, :resource_revision_changed} = Activation.close_resource(c.activation, self(), node(), "events", 0)
    assert {:ok, ^next} = Mirror.lookup(c.jido, c.activation, "events")
    {:ok, publisher} = Mirror.publisher(next)
    fresh = signal("after")
    assert {:ok, _} = Bridge.publish(publisher, fresh)
    eventually(fn -> length(Jido.AgentServer.snapshot(c.agent).agent.state.events) == 2 end)
    assert Enum.map(Jido.AgentServer.snapshot(c.agent).agent.state.events, & &1.id) == ["before", "after"]
    finish(c)
  end

  test "bridge crash permits replacement after its mirror confirms export task cleanup", c do
    transport = start_supervised!(RecordingTransport)
    :ok = RecordingTransport.hold(transport)
    targets = [%{host: :held@host, transport: RecordingTransport, handle: RecordingTransport.endpoint(transport)}]
    assert :ok = Bridge.set_targets(c.components.bridge, targets)
    {:ok, old_publisher} = Mirror.publisher(c.mirror)
    assert {:ok, %{local: :accepted}} = Bridge.publish(old_publisher, signal("interrupted"))
    eventually(fn -> RecordingTransport.pending(transport) == 1 end)
    [export_task] = RecordingTransport.callers(transport)
    export_monitor = Process.monitor(export_task)
    monitor = Process.monitor(c.mirror)
    Process.exit(c.components.bridge, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5000
    assert_receive {:DOWN, ^export_monitor, :process, ^export_task, _}, 5000
    assert {:error, :closed} = Gate.status(old_publisher.gate)
    assert {:ok, %{phase: :settled}} = Activation.resource_state(c.activation, self(), node(), "events")
    assert :ok = Activation.prepare_resource(c.activation, self(), node(), "events", 1)
    {:ok, replacement} = Mirror.ensure(Keyword.put(c.opts, :revision, 1))
    watch(replacement)
    assert :ok = Mirror.attach(replacement, c.ref, c.agent)
    assert :ok = Mirror.connect(replacement, [])
    assert {:ok, agent} = Jido.resolve_agent(c.jido, c.ref)
    assert agent == c.agent
    {:ok, publisher} = Mirror.publisher(replacement)
    assert {:ok, _} = Bridge.publish(publisher, signal("fresh"))
    eventually(fn -> length(Jido.AgentServer.snapshot(agent).agent.state.events) == 2 end)
    assert [%{id: "interrupted"}, %{id: "fresh"}] = Jido.AgentServer.snapshot(agent).agent.state.events
    assert [%{signal: %{id: "interrupted"}}] = RecordingTransport.exports(transport)
    finish(c)
  end

  test "abrupt mirror loss cannot authorize replacement from missing processes", c do
    monitor = Process.monitor(c.mirror)
    Process.exit(c.mirror, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5000
    eventually(fn -> Enum.all?(Map.values(c.components), &(not Process.alive?(&1))) end)
    assert :ok = Activation.close_resource(c.activation, self(), node(), "events", 0)
    assert {:error, :mirror_cleanup_uncertain} = Mirror.stop_generation(c.jido, c.activation, self(), "events", 0)

    assert {:error, :resource_cleanup_unconfirmed} =
             Activation.prepare_resource(c.activation, self(), node(), "events", 1)

    assert {:error, :resource_revision_changed} = Mirror.ensure(Keyword.put(c.opts, :revision, 1))
    assert Process.alive?(c.agent)
    assert :ok = Activation.close(c.activation, self())
    assert {:error, :resource_cleanup_unconfirmed} = Activation.settle(c.activation, self())
  end

  def hold_bus(_, _, %{bus_name: name}, {name, observer}) do
    send(observer, {:bus_waiting, self()})

    receive do
      :continue_bus -> :ok
    after
      5000 -> raise "Bus barrier timed out"
    end
  end

  def hold_bus(_, _, _, _), do: :ok

  defp watch(mirror) do
    components = Mirror.status(mirror).components
    on_exit(fn -> eventually(fn -> Enum.all?([mirror | Map.values(components)], &(not Process.alive?(&1))) end) end)
    components
  end

  defp finish(c) do
    assert :ok = Activation.close(c.activation, self())
    assert :ok = Mirror.cleanup(c.jido, c.activation, self())
    assert :ok = Activation.settle(c.activation, self())
    assert :ok = Jido.stop_agent_ref(c.jido, c.ref)
    refute Process.alive?(c.agent)
  end

  defp signal(id), do: Jido.Signal.new!(%{id: id, type: "counter.changed", source: "/generation-test", data: %{}})
end
