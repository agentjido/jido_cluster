defmodule Jido.Cluster.Federation.Binding do
  @moduledoc """
  Owns local subscriptions for one declared Ref and exact Agent incarnation.

  Attachment requires a ready local Agent whose Ref resolves to the supplied
  target PID. The Bus sends each Signal directly to that Agent's normal handler.
  This process handles control only; it does not forward or retain event payloads.
  Attachment is idempotent for this fixed target. A replacement PID needs a new
  accepted binding; directory changes never authorize automatic attachment.

  Each exact allowed type has a separate ephemeral Bus subscription. An attach
  failure removes the subscriptions already created by that attempt. Detach
  closes the binding before it reports success. Agent, core, and Bus monitors
  expose loss. Readiness is an observation of the owned attachment and current
  Agent, not an acknowledgement of event consumption or a durable cursor.
  """
  use GenServer, restart: :temporary

  alias Jido.Agent.Ref
  alias Jido.AgentServer
  alias Jido.Cluster.Federation.{Channel, Limits}
  alias Jido.Signal.Bus

  @doc "Starts a control process without attaching or starting an Agent."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Attaches all exact types to the accepted local Agent incarnation."
  @spec attach(pid(), timeout()) :: :ok | {:error, term()}
  def attach(binding, timeout \\ 5000) do
    GenServer.call(binding, :attach, timeout)
  catch
    :exit, _ -> {:error, :attachment_uncertain}
  end

  @doc "Removes owned subscriptions and permanently closes this binding."
  @spec detach(pid(), timeout()) :: :ok | {:error, term()}
  def detach(binding, timeout \\ 5000) do
    GenServer.call(binding, :detach, timeout)
  catch
    :exit, _ -> {:error, :detach_uncertain}
  end

  @doc "Reports logical identity, fixed target, and current attachment readiness."
  @spec status(pid()) :: map()
  def status(binding), do: GenServer.call(binding, :status)

  @doc "Returns the stable logical binding ID for a channel and Agent Ref."
  @spec id(tuple(), Ref.t()) :: String.t()
  def id(scope, ref) do
    :crypto.hash(:sha256, :erlang.term_to_binary({scope, Ref.to_map!(ref)}))
    |> Base.url_encode64(padding: false)
  end

  @impl true
  def init(opts) do
    case config(opts) do
      {:ok, config} ->
        generation = Jido.generate_id()
        paths = Enum.map(config.types, &%{type: &1, id: generation <> ":" <> &1})

        monitors =
          Map.new([bus: config.bus, agent: config.target, core: config.core], fn {role, pid} ->
            {Process.monitor(pid), role}
          end)

        {:ok, %{config: config, paths: paths, owned: [], monitors: monitors, phase: :pending, reason: nil}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:attach, _, %{phase: phase} = state) when phase in [:detached, :lost, :uncertain],
    do: {:reply, {:error, :binding_closed}, state}

  def handle_call(:attach, _, %{phase: :attached} = state),
    do: {:reply, target_ready(state.config), state}

  def handle_call(:attach, _, state) do
    case target_ready(state.config) do
      :ok ->
        {result, state} = subscribe(state)
        {:reply, result, state}

      {:error, reason} = error ->
        {:reply, error, %{state | reason: reason}}
    end
  end

  def handle_call(:detach, _, state) do
    {result, state} = retire(state, :detached, nil)
    {:reply, result, state}
  end

  def handle_call(:status, _, state) do
    current = if state.phase == :attached, do: target_ready(state.config), else: {:error, state.reason}
    ready = state.phase == :attached and current == :ok

    reason =
      case current do
        :ok -> nil
        {:error, reason} -> reason
      end

    result =
      state.config
      |> Map.take([:scope, :ref, :target, :required])
      |> Map.merge(%{
        id: id(state.config.scope, state.config.ref),
        phase: state.phase,
        ready: ready,
        reason: reason,
        subscription_count: length(state.owned),
        subscriptions: Enum.map(state.paths, &Map.put(&1, :attached, &1.id in state.owned))
      })

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, role} ->
        {_, state} = retire(state, :lost, {role, :down})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    retire(state, :detached, nil)
    :ok
  end

  defp subscribe(state) do
    result =
      Enum.reduce_while(state.paths, {:ok, state}, fn path, {:ok, acc} ->
        case subscribe_path(acc.config, path) do
          :ok -> {:cont, {:ok, %{acc | owned: [path.id | acc.owned]}}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case result do
      {:ok, next} -> finish_attach(next)
      {:error, reason, next} -> failed_attach(next, reason)
    end
  end

  defp finish_attach(state) do
    case target_ready(state.config) do
      :ok -> {:ok, %{state | phase: :attached, reason: nil}}
      {:error, reason} -> failed_attach(state, reason)
    end
  end

  defp failed_attach(state, reason) do
    {cleanup, next} = retire(state, :pending, reason)
    result = if cleanup == :ok, do: {:error, reason}, else: {:error, :attachment_uncertain}
    {result, next}
  end

  defp subscribe_path(config, path) do
    case Bus.subscribe(config.bus, path.type, target: config.target, subscription_id: path.id) do
      {:ok, id} when id == path.id -> :ok
      {:error, reason} -> {:error, {:subscribe, reason}}
    end
  catch
    :exit, _ -> {:error, :bus_unavailable}
  end

  defp retire(state, phase, reason) do
    unresolved = Enum.filter(state.owned, &(unsubscribe(state.config.bus, &1) != :ok))

    if unresolved == [] do
      {:ok, %{state | owned: [], phase: phase, reason: reason}}
    else
      {{:error, :detach_uncertain}, %{state | owned: unresolved, phase: :uncertain, reason: :detach_uncertain}}
    end
  end

  defp unsubscribe(bus, id) do
    case Bus.unsubscribe(bus, id) do
      :ok -> :ok
      {:error, :subscription_not_found} -> :ok
      _ -> absent_bus(bus)
    end
  catch
    :exit, _ -> absent_bus(bus)
  end

  defp absent_bus(bus), do: if(Process.alive?(bus), do: {:error, :detach_uncertain}, else: :ok)

  defp target_ready(config) do
    with true <- Process.alive?(config.bus),
         true <- Process.whereis(config.jido) == config.core,
         {:ok, target} <- Jido.resolve_agent(config.jido, config.ref),
         true <- target == config.target,
         :ok <- AgentServer.await_ready(target, config.ready_timeout),
         {:ok, ^target} <- Jido.resolve_agent(config.jido, config.ref) do
      :ok
    else
      _ -> {:error, :target_not_ready}
    end
  catch
    :exit, _ -> {:error, :target_not_ready}
  end

  defp config(opts) do
    allowed = [:jido, :bus, :scope, :types, :ref, :target, :required, :ready_timeout]

    with true <- Keyword.keyword?(opts),
         true <- length(opts) == map_size(Map.new(opts)) and Keyword.keys(opts) -- allowed == [],
         config = opts |> Map.new() |> Map.put_new(:ready_timeout, 100),
         %{
           jido: jido,
           bus: bus,
           scope: {ns, _, _} = scope,
           types: types,
           ref: ref,
           target: target,
           required: required,
           ready_timeout: timeout
         } <- config,
         true <- is_atom(jido) and is_pid(bus) and is_pid(target) and is_boolean(required),
         true <- node(bus) == node() and node(target) == node(),
         true <- Process.alive?(bus),
         true <- is_integer(timeout) and timeout in 1..5000,
         {:ok, ^ref} <- Ref.validate(ref),
         true <- ns == ref.namespace and ns == Jido.namespace(jido),
         core when is_pid(core) <- Process.whereis(jido),
         :ok <- Channel.validate(scope, types, %Limits{}) do
      {:ok, Map.put(config, :core, core)}
    else
      _ -> {:error, :invalid_binding}
    end
  end
end
