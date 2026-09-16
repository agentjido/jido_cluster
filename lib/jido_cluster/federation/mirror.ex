defmodule Jido.Cluster.Federation.Mirror do
  @moduledoc """
  Owns one host-local channel generation for an exact deployment activation.

  The application supervisor owns this process, not the caller that requests it.
  Its name is registered before activation authorization. Cleanup first closes
  activation admission, then finds every intended mirror by its stable key. This
  order also covers a start whose reply was lost. Stop requires closed admission;
  it confirms the exit of the owned Bus, receiver, bridge, and bridge tasks.

  Core or confirmed deployment-owner exit closes the local generation. Owner
  disconnect retains it with uncertain control; disconnect is not cleanup proof.
  No child restarts within a generation. Declared bindings attach only to exact
  local Agent incarnations. Required binding readiness is separate from Agent
  readiness and transport health. This module does not start Agents or discover
  remote interest.

  A mirror claims an exact resource revision, starting at zero. The deployment
  owner can close that revision without closing the deployment. After confirmed
  component cleanup, the owner can prepare its immediate successor. A new mirror
  can attach to the same ready Agent with new local subscription IDs. This
  primitive does not journal intent or choose a location revision.

  The local supervisor owns a dedicated export task supervisor independently of
  the bridge. A bridge crash therefore permits orderly task cleanup by the
  mirror. Abrupt mirror or export-supervisor loss retains cleanup uncertainty.
  """
  use GenServer, restart: :temporary, shutdown: :infinity

  alias Jido.Agent.Ref
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Binding, Bridge, Channel, Connections, Limits}
  alias Jido.Cluster.Federation.Transport.Receiver
  alias Jido.Signal.Bus

  @registry Jido.Cluster.FederationRegistry
  @supervisor Jido.Cluster.FederationSupervisor

  @doc "Starts or finds a mirror with the same exact configuration."
  @spec ensure(keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure(opts) do
    with {:ok, config} <- config(opts) do
      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, config}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> GenServer.call(pid, {:ensure, config})
        error -> error
      end
    end
  catch
    :exit, _ -> {:error, :mirror_start_uncertain}
  end

  @doc "Starts a linked mirror with configuration validated by ensure/1."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: name(config))

  @doc "Finds a mirror without a creation receipt."
  @spec lookup(atom(), map(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(jido, activation, channel) do
    case Registry.lookup(@registry, {jido, activation.id, channel}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "Stops an exact mirror after activation admission has been closed."
  @spec stop(atom(), map(), pid(), String.t()) :: :ok | {:error, term()}
  def stop(jido, activation, owner, channel) do
    case authorize(activation, owner) do
      {:error, :activation_closed} -> stop_closed(jido, activation, owner, channel)
      :ok -> {:error, :activation_open}
      error -> error
    end
  catch
    :exit, _ -> {:error, :mirror_cleanup_uncertain}
  end

  @doc "Stops only a closed resource revision, without closing the deployment activation."
  @spec stop_generation(atom(), map(), pid(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def stop_generation(jido, activation, owner, channel, revision) do
    with {:ok, resource} <- Activation.resource_state(activation, owner, node(), channel),
         true <- resource.revision == revision do
      case resource do
        %{phase: :settled} -> :ok
        %{phase: :closing, owner: pid} -> stop_generation_process(jido, activation, owner, channel, revision, pid)
        _ -> {:error, :resource_open}
      end
    else
      false -> {:error, :resource_revision_changed}
      error -> error
    end
  catch
    :exit, _ -> {:error, :mirror_cleanup_uncertain}
  end

  @doc "Closes all recorded host mirrors after the deployment owner closes admission."
  @spec cleanup(atom(), map() | nil, pid()) :: :ok | {:error, term()}
  def cleanup(_jido, nil, _owner), do: :ok

  def cleanup(jido, activation, owner) do
    with {:ok, keys} <- Activation.resources(activation, owner) do
      Enum.reduce_while(keys, :ok, &cleanup_key(&1, &2, jido, activation, owner))
    end
  catch
    :exit, _ -> {:error, :mirror_cleanup_uncertain}
  end

  @doc "Returns local component handles and exact lifetime identity without payloads."
  @spec status(pid(), timeout()) :: map()
  def status(mirror, timeout \\ 5000), do: GenServer.call(mirror, :status, timeout)

  @doc "Returns a cached bridge handle after the fixed target set is configured."
  @spec publisher(pid()) :: {:ok, map()} | {:error, term()}
  def publisher(mirror), do: GenServer.call(mirror, :publisher)

  @doc "Attaches one declared Ref to its exact accepted local Agent PID."
  @spec attach(pid(), Ref.t(), pid()) :: :ok | {:error, term()}
  def attach(mirror, ref, target) do
    GenServer.call(mirror, {:attach, ref, target}, 10_000)
  catch
    :exit, _ -> {:error, :attachment_uncertain}
  end

  @doc "Establishes a fixed interested-host set with one owned sender attempt per host."
  @spec connect(pid(), [map()]) :: :ok | {:error, term()}
  def connect(mirror, destinations) do
    GenServer.call(mirror, {:connect, destinations}, 10_000)
  catch
    :exit, _ -> {:error, :connection_setup_uncertain}
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    with :ok <- same_core(config),
         :ok <- Activation.claim_resource(config.activation, config.owner, config.channel, config.revision) do
      initialize(config)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initialize(config) do
    case start_components(config) do
      {:ok, supervisor, components} ->
        monitors = Map.new(components, fn {role, pid} -> {Process.monitor(pid), role} end)

        {:ok,
         %{
           config: config,
           supervisor: supervisor,
           components: components,
           monitors: monitors,
           down: %{},
           bindings: %{},
           destinations: nil,
           configured: false,
           publisher: Bridge.endpoint(components.bridge),
           connections: [],
           core_monitor: Process.monitor(config.core),
           owner_monitor: Process.monitor(config.owner),
           control: :ready
         }}

      {:error, reason} ->
        Activation.settle_resource(config.activation, config.owner, config.channel, config.revision)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:ensure, config}, _, state) do
    result =
      with true <- config == state.config,
           :ok <- same_core(config),
           :ok <- authorize_resource(config),
           do: {:ok, self()}

    case result do
      {:ok, _} ->
        Process.demonitor(state.owner_monitor, [:flush])
        {:reply, result, %{state | owner_monitor: Process.monitor(config.owner), control: :ready}}

      false ->
        {:reply, {:error, :mirror_config_mismatch}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _, state) do
    result = Map.take(state.config, [:scope, :activation, :owner, :core, :revision])
    bindings = Enum.map(state.config.bindings, &binding_status(&1, state))
    connections = Enum.map(state.connections, &Connections.status/1)

    result =
      Map.merge(result, %{
        control: state.control,
        components: state.components,
        bindings: bindings,
        binding_readiness: binding_readiness(bindings),
        connections: connections,
        configured: state.configured,
        federation_health: if(state.configured, do: connection_health(connections), else: :pending)
      })

    {:reply, result, state}
  end

  def handle_call(:publisher, _, state) do
    result =
      with :ok <- authorize_resource(state.config),
           true <- state.configured,
           do: {:ok, state.publisher}

    result = if result == false, do: {:error, :publisher_pending}, else: result
    {:reply, result, state}
  end

  def handle_call({:attach, ref, target}, _, state) do
    with :ok <- authorize_resource(state.config),
         %{required: required} <- Enum.find(state.config.bindings, &(&1.ref == ref)),
         true <- is_pid(target) and node(target) == node() do
      {result, state} = attach_binding(state, ref, target, required)
      {:reply, result, state}
    else
      nil -> {:reply, {:error, :binding_not_declared}, state}
      false -> {:reply, {:error, :invalid_target}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:connect, destinations}, _, state) do
    with :ok <- authorize_resource(state.config),
         :ok <- Connections.validate(destinations, state.config),
         destinations = Enum.sort_by(destinations, & &1.host),
         true <- state.destinations in [nil, destinations] do
      next = if is_nil(state.destinations), do: open_connections(state, destinations), else: state
      result = Bridge.set_targets(next.components.bridge, Connections.targets(next.connections))
      {:reply, result, %{next | configured: next.configured or result == :ok}}
    else
      false -> {:reply, {:error, :interest_changed}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, :noconnection}, %{owner_monitor: ref} = state),
    do: {:noreply, %{state | control: :uncertain}}

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    state =
      case Map.fetch(state.monitors, ref) do
        {:ok, role} -> %{state | down: Map.put(state.down, role, reason)}
        :error -> state
      end

    case Map.get(state.monitors, ref) do
      {:connection, _} ->
        {:noreply, state}

      _ ->
        if ref in [state.core_monitor, state.owner_monitor] or Map.has_key?(state.monitors, ref),
          do: {:stop, :normal, state},
          else: {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _}, %{supervisor: pid} = state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor, :shutdown, :infinity)

    if children_settled?(state),
      do:
        Activation.settle_resource(
          state.config.activation,
          state.config.owner,
          state.config.channel,
          state.config.revision
        )

    :ok
  end

  defp children_settled?(state) do
    results =
      Enum.map(state.monitors, fn {ref, role} ->
        reason =
          case Map.fetch(state.down, role) do
            {:ok, reason} ->
              reason

            :error ->
              receive do
                {:DOWN, ^ref, :process, _, reason} -> reason
              after
                5000 -> :unconfirmed
              end
          end

        {role, reason}
      end)

    Enum.all?(results, fn
      {:tasks, reason} -> reason in [:normal, :shutdown]
      {_, reason} -> reason not in [:unconfirmed, :noconnection, :noproc]
    end)
  end

  defp attach_binding(state, ref, target, required) do
    case Map.get(state.bindings, ref) do
      %{pid: pid, target: ^target} -> {Binding.attach(pid), state}
      %{target: _} -> {{:error, :binding_target_changed}, state}
      nil -> start_binding(state, ref, target, required)
    end
  end

  defp open_connections(state, destinations) do
    connections = Enum.map(destinations, &Connections.open(&1, state.supervisor))
    state = %{state | destinations: destinations, connections: connections}

    Enum.reduce(connections, state, fn
      %{pid: nil}, acc ->
        acc

      %{host: host, pid: pid}, acc ->
        role = {:connection, host}

        %{
          acc
          | components: Map.put(acc.components, role, pid),
            monitors: Map.put(acc.monitors, Process.monitor(pid), role)
        }
    end)
  end

  defp connection_health(connections) do
    cond do
      Enum.any?(connections, &(&1.health == :uncertain)) -> :uncertain
      Enum.any?(connections, &(&1.health != :healthy)) -> :degraded
      true -> :healthy
    end
  end

  defp start_binding(state, ref, target, required) do
    config = state.config

    opts = [
      jido: config.jido,
      bus: state.components.bus,
      scope: config.scope,
      types: config.types,
      ref: ref,
      target: target,
      required: required
    ]

    case DynamicSupervisor.start_child(state.supervisor, {Binding, opts}) do
      {:ok, pid} ->
        role = {:binding, ref}

        next = %{
          state
          | bindings: Map.put(state.bindings, ref, %{pid: pid, target: target}),
            components: Map.put(state.components, role, pid),
            monitors: Map.put(state.monitors, Process.monitor(pid), role)
        }

        {Binding.attach(pid), next}

      error ->
        {error, state}
    end
  end

  defp binding_status(declaration, state) do
    case Map.get(state.bindings, declaration.ref) do
      %{pid: pid} ->
        Binding.status(pid)

      nil ->
        Map.merge(declaration, %{
          id: Binding.id(state.config.scope, declaration.ref),
          phase: :pending,
          ready: false,
          reason: :not_attached,
          target: nil,
          subscription_count: 0
        })
    end
  catch
    :exit, _ -> Map.merge(declaration, %{phase: :lost, ready: false, reason: :binding_unavailable})
  end

  defp binding_readiness(bindings) do
    missing = Enum.filter(bindings, &(&1.required and not &1.ready))

    cond do
      missing == [] -> :ready
      Enum.any?(missing, &(&1.phase in [:lost, :uncertain])) -> :degraded
      true -> :pending
    end
  end

  defp stop_resource(jido, activation, owner, channel, pid) do
    case lookup(jido, activation, channel) do
      {:ok, ^pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
      _ -> :ok
    end

    case Activation.resource(activation, owner, node(), channel) do
      {:ok, :settled} -> :ok
      _ -> {:error, :mirror_cleanup_uncertain}
    end
  end

  defp stop_generation_process(jido, activation, owner, channel, revision, pid) do
    case lookup(jido, activation, channel) do
      {:ok, ^pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
      _ -> :ok
    end

    case Activation.resource_state(activation, owner, node(), channel) do
      {:ok, %{revision: ^revision, phase: :settled}} -> :ok
      {:ok, %{revision: current}} when current != revision -> {:error, :resource_revision_changed}
      _ -> {:error, :mirror_cleanup_uncertain}
    end
  end

  defp stop_closed(jido, activation, owner, channel) do
    case Activation.resource(activation, owner, node(), channel) do
      {:ok, status} when status in [:unstarted, :settled] -> :ok
      {:ok, {:active, pid}} -> stop_resource(jido, activation, owner, channel, pid)
      error -> error
    end
  end

  defp cleanup_key({host, channel}, :ok, jido, activation, owner) do
    result =
      case Activation.resource_state(activation, owner, host, channel) do
        {:ok, %{phase: phase}} when phase in [:settled, :unstarted] -> :ok
        {:ok, _} -> stop_on_host(host, jido, activation, owner, channel)
        error -> error
      end

    case result do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:mirror_cleanup, host, channel, reason}}}
    end
  end

  defp stop_on_host(host, jido, activation, owner, channel) do
    if host in [node() | Node.list()],
      do: :erpc.call(host, __MODULE__, :stop, [jido, activation, owner, channel], 5000),
      else: {:error, :host_unreachable}
  catch
    _, _ -> {:error, :mirror_cleanup_uncertain}
  end

  defp start_components(config) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    result =
      with {:ok, bus} <- start_bus(supervisor, config),
           common = [bus: bus, scope: config.scope, types: config.types, limits: config.limits],
           {:ok, receiver} <-
             DynamicSupervisor.start_child(supervisor, {Receiver, common ++ [allowed_nodes: config.allowed_nodes]}),
           tasks_spec = Supervisor.child_spec({Task.Supervisor, []}, restart: :temporary, shutdown: :infinity),
           {:ok, tasks} <- DynamicSupervisor.start_child(supervisor, tasks_spec),
           bridge_spec =
             Supervisor.child_spec({Bridge, common ++ [targets: [], task_supervisor: tasks]}, shutdown: :infinity),
           {:ok, bridge} <- DynamicSupervisor.start_child(supervisor, bridge_spec) do
        {:ok, supervisor, %{bus: bus, receiver: receiver, bridge: bridge, tasks: tasks}}
      end

    case result do
      {:ok, _, _} ->
        result

      error ->
        Supervisor.stop(supervisor, :shutdown, :infinity)
        error
    end
  end

  defp start_bus(supervisor, config) do
    bus_name = "cluster-channel:" <> config.activation.id <> ":" <> config.channel
    opts = [name: bus_name, registry: Jido.registry_name(config.jido), jido: config.jido, max_log_size: 1024]
    spec = Supervisor.child_spec({Bus, opts}, restart: :temporary)
    DynamicSupervisor.start_child(supervisor, spec)
  end

  defp name(config), do: {:via, Registry, {@registry, {config.jido, config.activation.id, config.channel}}}

  defp same_core(config) do
    if Process.whereis(config.jido) == config.core and Process.alive?(config.core),
      do: :ok,
      else: {:error, :core_lifetime_changed}
  end

  defp authorize(activation, owner) do
    if node(owner) == node(),
      do: Activation.authorize(activation, owner),
      else: :erpc.call(node(owner), Activation, :authorize, [activation, owner], 5000)
  catch
    _, _ -> {:error, :activation_unreachable}
  end

  defp authorize_resource(config) do
    Activation.authorize_resource(config.activation, config.owner, config.channel, config.revision)
  catch
    _, _ -> {:error, :activation_unreachable}
  end

  defp config(opts) do
    allowed = [:jido, :activation, :owner, :channel, :types, :limits, :allowed_nodes, :bindings, :revision]

    with true <- Keyword.keyword?(opts),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Keyword.keys(opts) -- allowed == [],
         values = opts |> Map.new() |> Map.put_new(:bindings, []) |> Map.put_new(:revision, 0),
         %{
           jido: jido,
           activation: activation,
           owner: owner,
           channel: channel,
           types: types,
           limits: %Limits{} = limits,
           allowed_nodes: hosts
         } = config <- values,
         true <- is_atom(jido) and is_pid(owner),
         true <- is_integer(config.revision) and config.revision in 0..9_007_199_254_740_991,
         %{namespace: ns, topology_id: topology, node: control} <- activation,
         true <- ns == Jido.namespace(jido) and control == Atom.to_string(node(owner)),
         core when is_pid(core) <- Process.whereis(jido),
         true <- is_list(hosts) and Enum.all?(hosts, &is_atom/1),
         true <- length(hosts) == length(Enum.uniq(hosts)) and length(hosts) <= limits.max_hosts,
         true <- valid_bindings?(config.bindings, ns),
         scope = {ns, topology, channel},
         :ok <- Channel.validate(scope, types, limits) do
      {:ok, config |> Map.put(:core, core) |> Map.put(:scope, scope) |> Map.put(:allowed_nodes, Enum.sort(hosts))}
    else
      _ -> {:error, :invalid_mirror}
    end
  end

  defp valid_bindings?(bindings, namespace) when is_list(bindings) and length(bindings) <= 64 do
    Enum.all?(bindings, fn
      %{ref: %Ref{namespace: ^namespace} = ref, required: required} = declaration when map_size(declaration) == 2 ->
        is_boolean(required) and match?({:ok, ^ref}, Ref.validate(ref))

      _ ->
        false
    end) and length(bindings) == length(Enum.uniq_by(bindings, & &1.ref))
  end

  defp valid_bindings?(_, _), do: false
end
