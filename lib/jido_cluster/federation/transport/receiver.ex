defmodule Jido.Cluster.Federation.Transport.Receiver do
  @moduledoc """
  Host-local Bus import with a fixed set of sender credits.

  Each connected sender gets one credit, charged at the maximum envelope size.
  That sender can transmit one envelope and must wait for its acknowledgement
  before transmitting another. Thus admitted payloads, including mailbox entries,
  cannot exceed the configured inbound slots or bytes. Credits remain charged
  across sender disconnect. Only confirmed sender exit or receiver generation
  closure releases them. This protocol assumes trusted Cluster senders.

  Imports append to the local Bus and never export. Acknowledgement establishes
  local append or within-window duplicate suppression, not Agent execution.
  Connection setup and status are control operations, outside payload admission.
  """
  use GenServer, restart: :temporary

  alias Jido.Cluster.Federation.{Channel, Dedup, Envelope, Gate, Limits}
  alias Jido.Signal.Bus

  @doc "Starts a receiver for an existing host-local Bus."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the destination descriptor used during bounded connection setup."
  @spec endpoint(pid()) :: map()
  def endpoint(receiver), do: GenServer.call(receiver, :endpoint)

  @doc "Requests one credit for the exact calling sender process."
  @spec open(pid()) :: {:ok, reference()} | {:error, term()}
  def open(receiver), do: GenServer.call(receiver, :open)

  @doc "Reports import results and retained sender credits without Signal payloads."
  @spec status(pid(), timeout()) :: map()
  def status(receiver, timeout \\ 5000), do: GenServer.call(receiver, :status, timeout)

  @impl true
  def init(opts) do
    case config(opts) do
      {:ok, config} ->
        {:ok,
         Map.merge(config, %{
           generation: Jido.generate_id(),
           gate: Gate.new(config.limits, :inbound),
           cache: Dedup.new(config.limits),
           credits: %{},
           bus_monitor: Process.monitor(config.bus),
           appended: 0,
           duplicates: 0,
           rejected: 0
         })}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:endpoint, _, state) do
    result = Map.take(state, [:scope, :types, :limits, :generation]) |> Map.put(:pid, self())
    {:reply, result, state}
  end

  def handle_call(:status, _, state) do
    result = Map.take(state, [:scope, :generation, :appended, :duplicates, :rejected])

    result =
      Map.merge(result, %{
        credits: map_size(state.credits),
        capacity: Gate.status(state.gate),
        uncertain_credits: Enum.count(state.credits, fn {_, credit} -> credit.uncertain end)
      })

    {:reply, result, state}
  end

  def handle_call(:open, {sender, _}, state) do
    cond do
      node(sender) not in state.allowed_nodes -> {:reply, {:error, :host_not_allowed}, state}
      Map.has_key?(state.credits, sender) -> {:reply, {:ok, state.credits[sender].token}, state}
      map_size(state.credits) >= state.limits.max_hosts -> {:reply, {:error, :capacity}, state}
      true -> grant(sender, state)
    end
  end

  @impl true
  def handle_info({:cluster_federation, token, transmission, sender, envelope}, state) do
    {result, state} =
      case Map.get(state.credits, sender) do
        %{token: ^token} = credit -> import_envelope(envelope, rearm(sender, credit, state))
        _ -> {{:error, :invalid_credit}, %{state | rejected: state.rejected + 1}}
      end

    Process.send(sender, {:cluster_federation_ack, token, transmission, result}, [:nosuspend, :noconnect])
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, %{bus_monitor: monitor} = state),
    do: {:stop, {:bus_down, reason}, state}

  def handle_info({:DOWN, monitor, :process, sender, reason}, state) do
    case Map.get(state.credits, sender) do
      %{monitor: ^monitor} = credit when reason == :noconnection ->
        {:noreply, put_in(state, [:credits, sender], %{credit | uncertain: true})}

      %{monitor: ^monitor} = credit ->
        :ok = Gate.release(state.gate, credit.permit)
        {:noreply, %{state | credits: Map.delete(state.credits, sender)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp rearm(sender, %{uncertain: true} = credit, state) do
    Process.demonitor(credit.monitor, [:flush])
    put_in(state, [:credits, sender], %{credit | monitor: Process.monitor(sender), uncertain: false})
  end

  defp rearm(_, _, state), do: state

  defp grant(sender, state) do
    case Gate.reserve(state.gate, state.limits.max_envelope_bytes) do
      {:ok, permit} ->
        token = make_ref()
        credit = %{token: token, permit: permit, monitor: Process.monitor(sender), uncertain: false}
        {:reply, {:ok, token}, put_in(state, [:credits, sender], credit)}

      error ->
        {:reply, error, state}
    end
  end

  defp import_envelope(envelope, state) do
    case Envelope.validate(envelope, state.scope, state.types, state.limits) do
      {:ok, signal} ->
        case Dedup.admit(state.cache, Envelope.identity(envelope), System.monotonic_time(:millisecond)) do
          {:duplicate, cache} -> {{:ok, :duplicate}, %{state | cache: cache, duplicates: state.duplicates + 1}}
          {:new, cache} -> append(signal, cache, state)
          {:error, reason, cache} -> {{:error, reason}, %{state | cache: cache, rejected: state.rejected + 1}}
        end

      error ->
        {error, %{state | rejected: state.rejected + 1}}
    end
  end

  defp append(signal, cache, state) do
    case Bus.publish(state.bus, [signal]) do
      {:ok, [_]} -> {{:ok, :appended}, %{state | cache: cache, appended: state.appended + 1}}
      {:error, reason} -> {{:error, {:local_append, reason}}, %{state | rejected: state.rejected + 1}}
    end
  end

  defp config(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == map_size(Map.new(opts)),
      do: validate_config(Map.new(opts)),
      else: {:error, :invalid_receiver}
  end

  defp config(_), do: {:error, :invalid_receiver}

  defp validate_config(
         %{bus: bus, scope: scope, types: types, limits: %Limits{} = limits, allowed_nodes: nodes} =
           config
       )
       when map_size(config) == 5 and is_pid(bus) and node(bus) == node() and is_list(nodes) do
    with true <- Process.alive?(bus) and valid_nodes?(nodes, limits.max_hosts),
         :ok <- Channel.validate(scope, types, limits) do
      {:ok, config}
    else
      _ -> {:error, :invalid_receiver}
    end
  end

  defp validate_config(_), do: {:error, :invalid_receiver}

  defp valid_nodes?(nodes, limit),
    do:
      nodes != [] and length(nodes) <= limit and length(Enum.uniq(nodes)) == length(nodes) and
        Enum.all?(nodes, &(is_atom(&1) and &1 not in [nil, true, false]))

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, Map.take(status.state, [:scope, :generation, :appended, :duplicates, :rejected]))
    |> Map.put(:message, :payload_redacted)
    |> Map.put(:log, [])
  end
end
