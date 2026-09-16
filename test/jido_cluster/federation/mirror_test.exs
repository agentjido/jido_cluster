defmodule JidoCluster.Federation.MirrorTest do
  use ExUnit.Case, async: false
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Bridge, Gate, Limits, Mirror}
  alias Jido.Signal.Bus

  setup do
    jido = __MODULE__.Core
    core = start_supervised!({Jido, name: jido, namespace: "mirror-test"})
    activation = Activation.new({"mirror-test", Jido.generate_id()}, "work")
    :ok = Activation.claim(activation, self())
    {:ok, limits} = Limits.new([])

    opts = [
      jido: jido,
      activation: activation,
      owner: self(),
      channel: "events",
      types: ["counter.changed"],
      limits: limits,
      allowed_nodes: [node()]
    ]

    %{jido: jido, core: core, activation: activation, opts: opts}
  end

  test "concurrent requests share a generation that outlives each requester", c do
    tasks = for _ <- 1..64, do: Task.async(fn -> Mirror.ensure(c.opts) end)
    results = Task.await_many(tasks)
    assert [{:ok, mirror}] = Enum.uniq(results)
    components = watch_cleanup(mirror)
    assert {:ok, ^mirror} = Mirror.lookup(c.jido, c.activation, "events")
    assert %{core: core, owner: owner, control: :ready} = Mirror.status(mirror)
    assert core == c.core and owner == self()
    signal = Jido.Signal.new!(%{type: "counter.changed", source: "/test", data: %{count: 1}})
    endpoint = Bridge.endpoint(components.bridge)
    assert {:ok, %{targets: []}} = Bridge.publish(endpoint, signal)
    assert {:ok, [record]} = Bus.replay(components.bus, "counter.changed")
    assert record.signal == signal
    assert {:error, :activation_open} = Mirror.stop(c.jido, c.activation, self(), "events")
    assert :ok = close(c)
    refute Process.alive?(mirror)
    assert Enum.all?(Map.values(components), &(not Process.alive?(&1)))
    assert {:error, :closed} = Gate.status(endpoint.gate)
  end

  test "closed admission rejects delayed starts and permits idempotent absent cleanup", c do
    assert :ok = Activation.close(c.activation, self())
    assert :ok = Mirror.stop(c.jido, c.activation, self(), "events")
    assert {:error, :activation_closed} = Mirror.ensure(c.opts)
    assert :ok = Activation.settle(c.activation, self())
    assert {:error, :activation_closed} = Mirror.ensure(c.opts)
    assert {:ok, :unstarted} = Activation.resource(c.activation, self(), node(), "events")
  end

  test "publisher remains closed until target configuration succeeds", c do
    {:ok, mirror} = Mirror.ensure(c.opts)
    components = watch_cleanup(mirror)
    endpoint = Bridge.endpoint(components.bridge)
    assert {:error, :publisher_pending} = Mirror.publisher(mirror)
    # Model a caller paused after low-level admission, before payload submission.
    {:ok, permit} = Gate.reserve(endpoint.gate, 1)
    assert {:error, :busy} = Mirror.connect(mirror, [])
    assert %{configured: false, federation_health: :pending} = Mirror.status(mirror)
    assert {:error, :publisher_pending} = Mirror.publisher(mirror)
    assert :ok = Gate.release(endpoint.gate, permit)
    assert :ok = Mirror.connect(mirror, [])
    assert {:ok, ^endpoint} = Mirror.publisher(mirror)
    assert :ok = Activation.close(c.activation, self())
    assert {:error, :activation_closed} = Mirror.publisher(mirror)
    assert :ok = close(c)
  end

  test "cleanup uses retained evidence when the creation receipt is discarded", c do
    task =
      Task.async(fn ->
        {:ok, _} = Mirror.ensure(c.opts)
        :receipt_discarded
      end)

    assert :receipt_discarded = Task.await(task)
    assert {:ok, mirror} = Mirror.lookup(c.jido, c.activation, "events")
    components = watch_cleanup(mirror)
    assert {:error, :resource_cleanup_unconfirmed} = Activation.settle(c.activation, self())
    assert :ok = close(c)
    assert :ok = Mirror.stop(c.jido, c.activation, self(), "events")
    assert {:ok, :settled} = Activation.resource(c.activation, self(), node(), "events")
    assert Enum.all?(Map.values(components), &(not Process.alive?(&1)))
  end

  test "an existing mirror rejects changed types and host configuration", c do
    {:ok, mirror} = Mirror.ensure(c.opts)
    watch_cleanup(mirror)
    assert {:error, :mirror_config_mismatch} = Mirror.ensure(Keyword.put(c.opts, :types, ["other.changed"]))
    assert {:error, :mirror_config_mismatch} = Mirror.ensure(Keyword.put(c.opts, :allowed_nodes, []))
    assert {:ok, ^mirror} = Mirror.ensure(c.opts)
    assert :ok = close(c)
  end

  test "invalid core scope and malformed configuration create no resource record", c do
    assert {:error, :invalid_mirror} = Mirror.ensure(Keyword.put(c.opts, :channel, ""))
    assert {:error, :invalid_mirror} = Mirror.ensure(Keyword.put(c.opts, :owner, nil))
    assert {:error, :invalid_mirror} = Mirror.ensure(c.opts ++ [channel: "duplicate"])
    other = %{c.activation | namespace: "other"}
    assert {:error, :invalid_mirror} = Mirror.ensure(Keyword.put(c.opts, :activation, other))
    assert {:ok, :unstarted} = Activation.resource(c.activation, self(), node(), "events")
    assert :ok = close(c)
  end

  test "core exit closes all channel resources without settling deployment cleanup", c do
    {:ok, mirror} = Mirror.ensure(c.opts)
    components = watch_cleanup(mirror)
    endpoint = Bridge.endpoint(components.bridge)
    monitor = Process.monitor(mirror)
    stop_supervised!(c.jido)
    assert_receive {:DOWN, ^monitor, :process, ^mirror, _}, 5000
    assert Enum.all?(Map.values(components), &(not Process.alive?(&1)))
    assert {:error, :closed} = Gate.status(endpoint.gate)
    owner = self()
    assert {:ok, {:active, ^owner}} = Activation.inspect(c.activation)
    assert {:ok, :settled} = Activation.resource(c.activation, self(), node(), "events")
    assert :ok = close(c)
  end

  test "a failed component closes the whole generation without child restart", c do
    {:ok, mirror} = Mirror.ensure(c.opts)
    components = watch_cleanup(mirror)
    monitor = Process.monitor(mirror)
    Process.exit(components.receiver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^mirror, :normal}, 5000
    assert Enum.all?(Map.values(components), &(not Process.alive?(&1)))
    assert {:error, :resource_cleanup_unconfirmed} = Mirror.ensure(c.opts)
    assert :ok = close(c)
  end

  test "abrupt mirror loss retains uncertainty even after its children exit", c do
    {:ok, mirror} = Mirror.ensure(c.opts)
    components = watch_cleanup(mirror)
    monitor = Process.monitor(mirror)
    Process.exit(mirror, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^mirror, :killed}
    eventually(fn -> Enum.all?(Map.values(components), &(not Process.alive?(&1))) end)
    assert {:error, :not_found} = Mirror.lookup(c.jido, c.activation, "events")
    assert {:ok, {:active, ^mirror}} = Activation.resource(c.activation, self(), node(), "events")
    assert {:error, :resource_cleanup_unconfirmed} = Mirror.ensure(c.opts)
    assert :ok = Activation.close(c.activation, self())
    assert {:error, :mirror_cleanup_uncertain} = Mirror.stop(c.jido, c.activation, self(), "events")
    assert {:error, :resource_cleanup_unconfirmed} = Activation.settle(c.activation, self())
  end

  test "closure racing with start leaves no admitted resources after confirmed cleanup", c do
    tasks = for _ <- 1..32, do: Task.async(fn -> Mirror.ensure(c.opts) end)
    assert :ok = Activation.close(c.activation, self())
    assert :ok = Mirror.stop(c.jido, c.activation, self(), "events")
    assert :ok = Activation.settle(c.activation, self())
    results = Task.await_many(tasks)

    assert Enum.all?(results, fn
             {:ok, pid} -> not Process.alive?(pid)
             {:error, reason} -> reason in [:activation_closed, :mirror_start_uncertain]
           end)

    assert {:error, :not_found} = Mirror.lookup(c.jido, c.activation, "events")
    assert {:error, :activation_closed} = Mirror.ensure(c.opts)
  end

  test "abrupt export supervisor loss cannot supply a child cleanup receipt", c do
    {:ok, mirror} = Mirror.ensure(c.opts)
    components = watch_cleanup(mirror)
    monitor = Process.monitor(mirror)
    Process.exit(components.tasks, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^mirror, :normal}, 5000
    assert Enum.all?(Map.values(components), &(not Process.alive?(&1)))
    assert :ok = Activation.close(c.activation, self())
    assert {:error, :mirror_cleanup_uncertain} = Mirror.stop(c.jido, c.activation, self(), "events")
    assert {:error, :resource_cleanup_unconfirmed} = Activation.settle(c.activation, self())
  end

  test "confirmed deployment owner exit closes volatile resources but does not settle the activation", c do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    activation = Activation.new({c.activation.namespace, c.activation.scope}, "owner-exit")
    assert :ok = Activation.claim(activation, owner)
    opts = c.opts |> Keyword.put(:activation, activation) |> Keyword.put(:owner, owner)
    {:ok, mirror} = Mirror.ensure(opts)
    components = watch_cleanup(mirror)
    monitor = Process.monitor(mirror)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^mirror, :normal}, 5000
    assert Enum.all?(Map.values(components), &(not Process.alive?(&1)))
    assert {:ok, :settled} = Activation.resource(activation, owner, node(), "events")
    assert {:error, :cleanup_unconfirmed} = Activation.inspect(activation)
    assert :ok = close(c)
  end

  test "required bindings control readiness while optional missing bindings remain visible", c do
    {:ok, required} = Jido.agent_ref(c.jido, "required")
    {:ok, optional} = Jido.agent_ref(c.jido, "optional")
    opts = Keyword.put(c.opts, :bindings, [%{ref: required, required: true}, %{ref: optional, required: false}])
    {:ok, mirror} = Mirror.ensure(opts)
    assert %{binding_readiness: :pending, bindings: [_, _]} = Mirror.status(mirror)
    assert {:error, :binding_not_declared} = Mirror.attach(mirror, :unknown, self())
    {:ok, agent} = Jido.start_agent_ref(c.jido, required, JidoCluster.Test.Federation.Subscriber)
    assert :ok = Mirror.attach(mirror, required, agent)
    assert :ok = Mirror.attach(mirror, required, agent)
    assert {:error, :binding_target_changed} = Mirror.attach(mirror, required, self())
    assert %{binding_readiness: :ready, bindings: [ready, missing], components: components} = Mirror.status(mirror)
    assert ready.ref == required and ready.ready
    assert missing.ref == optional and not missing.ready and missing.phase == :pending
    watch_cleanup(mirror)
    signal = Jido.Signal.new!(%{id: "subscribed", type: "counter.changed", source: "/test", data: %{count: 1}})
    assert {:ok, _} = Bridge.publish(Bridge.endpoint(components.bridge), signal)
    eventually(fn -> length(Jido.AgentServer.snapshot(agent).agent.state.events) == 1 end)
    assert [%{id: "subscribed"}] = Jido.AgentServer.snapshot(agent).agent.state.events
    assert :ok = Jido.stop_agent_ref(c.jido, required)
    eventually(fn -> Mirror.status(mirror).binding_readiness == :degraded end)
    assert Process.alive?(mirror)
    assert :ok = close(c)
  end

  defp close(c) do
    with :ok <- Activation.close(c.activation, self()),
         :ok <- Mirror.stop(c.jido, c.activation, self(), "events"),
         do: Activation.settle(c.activation, self())
  end

  defp watch_cleanup(mirror) do
    %{components: components} = Mirror.status(mirror)
    on_exit(fn -> eventually(fn -> Enum.all?([mirror | Map.values(components)], &(not Process.alive?(&1))) end) end)
    components
  end
end
