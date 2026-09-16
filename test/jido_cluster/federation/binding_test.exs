defmodule JidoCluster.Federation.BindingTest do
  use ExUnit.Case, async: false
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.Federation.Binding
  alias Jido.Signal.Bus
  alias JidoCluster.Test.Federation.Subscriber

  setup do
    jido = __MODULE__.Core
    start_supervised!({Jido, name: jido, namespace: "binding-test"})
    name = "binding-#{Jido.generate_id()}"
    bus = start_supervised!({Bus, name: name}, id: :bus)
    {:ok, ref} = Jido.agent_ref(jido, "subscriber")
    {:ok, agent} = Jido.start_agent_ref(jido, ref, Subscriber)
    :ok = Jido.AgentServer.await_ready(agent)

    opts = [
      jido: jido,
      bus: bus,
      scope: {"binding-test", "work", "events"},
      types: ["counter.changed", "counter.barrier"],
      ref: ref,
      target: agent,
      required: true
    ]

    binding = start_supervised!({Binding, opts})
    %{jido: jido, bus: bus, name: name, ref: ref, agent: agent, binding: binding, opts: opts}
  end

  test "attachment is idempotent and exact types use the normal Agent Signal path", c do
    assert %{ready: false, phase: :pending, subscription_count: 0} = Binding.status(c.binding)
    assert :ok = Binding.attach(c.binding)
    assert :ok = Binding.attach(c.binding)
    assert %{ready: true, phase: :attached, subscription_count: 2, target: target} = Binding.status(c.binding)
    assert target == c.agent
    accepted = signal("counter.changed", "accepted", %{count: 3, raw: <<255>>})
    excluded = signal("counter.hidden", "excluded", %{})
    barrier = signal("counter.barrier", "barrier", %{})
    assert {:ok, [_, _, _]} = Bus.publish(c.bus, [accepted, excluded, barrier])
    eventually(fn -> length(events(c.agent)) == 2 end)
    assert events(c.agent) == Enum.map([accepted, barrier], &Map.take(&1, [:id, :type, :source, :data]))
    assert %{state_version: 2} = Jido.AgentServer.snapshot(c.agent)
  end

  test "detach is idempotent and does not stop the Agent or unrelated subscriptions", c do
    assert :ok = Binding.attach(c.binding)
    {:ok, other} = Bus.subscribe(c.bus, "counter.changed", target: self())
    assert :ok = Binding.detach(c.binding)
    assert :ok = Binding.detach(c.binding)
    assert {:error, :binding_closed} = Binding.attach(c.binding)
    event = signal("counter.changed", "after-detach", %{})
    assert {:ok, [_]} = Bus.publish(c.bus, [event])
    assert_receive {:signal, ^event}
    assert {:ok, _} = Jido.AgentServer.call(c.agent, signal("counter.barrier", "barrier", %{}))
    assert [%{id: "barrier"}] = events(c.agent)
    assert %{phase: :detached, ready: false, subscription_count: 0} = Binding.status(c.binding)
    assert :ok = Bus.unsubscribe(c.bus, other)
  end

  test "a different Agent cannot receive a binding for the accepted Ref", c do
    {:ok, other_ref} = Jido.agent_ref(c.jido, "other")
    {:ok, other} = Jido.start_agent_ref(c.jido, other_ref, Subscriber)
    wrong = start_supervised!({Binding, Keyword.put(c.opts, :target, other)}, id: :wrong)
    assert {:error, :target_not_ready} = Binding.attach(wrong)
    assert %{ready: false, subscription_count: 0} = Binding.status(wrong)
    assert :ok = Binding.attach(c.binding)
    event = signal("counter.changed", "right-target", %{})
    assert {:ok, [_]} = Bus.publish(c.bus, [event])
    eventually(fn -> length(events(c.agent)) == 1 end)
    assert {:ok, _} = Jido.AgentServer.call(other, signal("counter.barrier", "other-barrier", %{}))
    assert [%{id: "other-barrier"}] = events(other)
  end

  test "Agent replacement under the same Ref does not reattach an old binding", c do
    assert :ok = Binding.attach(c.binding)
    assert :ok = Jido.stop_agent_ref(c.jido, c.ref)
    eventually(fn -> Binding.status(c.binding).phase == :lost end)
    {:ok, replacement} = Jido.start_agent_ref(c.jido, c.ref, Subscriber)
    assert {:error, :binding_closed} = Binding.attach(c.binding)
    assert %{ready: false, subscription_count: 0, target: target} = Binding.status(c.binding)
    assert target == c.agent
    assert {:ok, [_]} = Bus.publish(c.bus, [signal("counter.changed", "old-binding", %{})])
    assert {:ok, _} = Jido.AgentServer.call(replacement, signal("counter.barrier", "replacement-barrier", %{}))
    assert [%{id: "replacement-barrier"}] = events(replacement)
  end

  test "Bus loss reports lost attachment and leaves the Agent alive", c do
    assert :ok = Binding.attach(c.binding)
    stop_supervised!(:bus)
    eventually(fn -> Binding.status(c.binding).phase == :lost end)
    assert %{ready: false, reason: {:bus, :down}, subscription_count: 0} = Binding.status(c.binding)
    assert Process.alive?(c.agent)
    assert :ok = Binding.detach(c.binding)
  end

  test "invalid scope and duplicate options fail before subscription creation", c do
    for opts <- [
          Keyword.put(c.opts, :scope, {"other", "work", "events"}),
          Keyword.put(c.opts, :types, ["counter.**"]),
          c.opts ++ [required: false]
        ] do
      assert {:error, {:invalid_binding, _}} = start_supervised({Binding, opts}, id: :invalid)
    end

    assert %{ready: false, subscription_count: 0} = Binding.status(c.binding)
  end

  test "partial attachment failure removes every subscription created by the attempt", c do
    %{subscriptions: [first, second]} = Binding.status(c.binding)
    assert {:ok, _} = Bus.subscribe(c.bus, second.type, subscription_id: second.id, target: self())
    assert {:error, {:subscribe, :subscription_already_exists}} = Binding.attach(c.binding)
    assert %{ready: false, phase: :pending, subscription_count: 0} = Binding.status(c.binding)
    assert {:ok, _} = Bus.subscribe(c.bus, first.type, subscription_id: first.id, target: self())
    assert :ok = Bus.unsubscribe(c.bus, first.id)
    event = signal(second.type, "foreign-subscription", %{})
    assert {:ok, [_]} = Bus.publish(c.bus, [event])
    assert_receive {:signal, ^event}
    assert Process.alive?(c.agent)
    assert :ok = Bus.unsubscribe(c.bus, second.id)
    assert :ok = Binding.attach(c.binding)
    assert %{ready: true, subscription_count: 2} = Binding.status(c.binding)
  end

  test "an attachment timeout retains the in-progress attempt and a late result remains idempotent", c do
    handler = {__MODULE__, make_ref()}
    observer = self()

    assert :ok =
             :telemetry.attach(handler, [:jido, :signal, :bus, :subscription, :attached], &__MODULE__.hold_first/4, %{
               bus_name: c.name,
               observer: observer
             })

    on_exit(fn -> :telemetry.detach(handler) end)
    task = Task.async(fn -> Binding.attach(c.binding, 10) end)
    assert_receive {:subscription_waiting, bus, _id}
    assert bus == c.bus
    assert {:error, :attachment_uncertain} = Task.await(task)
    :ok = :telemetry.detach(handler)
    send(bus, :continue_subscription)
    eventually(fn -> Binding.status(c.binding).ready end)
    assert :ok = Binding.attach(c.binding)
    assert %{subscription_count: 2} = Binding.status(c.binding)
    event = signal("counter.changed", "after-timeout", %{})
    assert {:ok, [_]} = Bus.publish(c.bus, [event])
    eventually(fn -> length(events(c.agent)) == 1 end)
    assert [%{id: "after-timeout"}] = events(c.agent)
  end

  def hold_first(_, _, %{bus_name: name, subscription_id: id}, %{bus_name: name, observer: observer}) do
    send(observer, {:subscription_waiting, self(), id})

    receive do
      :continue_subscription -> :ok
    after
      5000 -> raise "subscription barrier timed out"
    end
  end

  def hold_first(_, _, _, _), do: :ok

  defp events(agent), do: Jido.AgentServer.snapshot(agent).agent.state.events
  defp signal(type, id, data), do: Jido.Signal.new!(%{id: id, type: type, source: "/binding-test", data: data})
end
