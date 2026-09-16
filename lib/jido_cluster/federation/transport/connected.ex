defmodule Jido.Cluster.Federation.Transport.Connected do
  @moduledoc """
  Connected-BEAM transport with one outstanding envelope per receiver credit.

  Callers acquire a local ETS slot before sending a payload to this process.
  Native send uses `:nosuspend` and `:noconnect`; it never queues a retry or starts
  a connection. An acknowledgement timeout reports uncertainty but retains the
  slot. A late acknowledgement releases it. Receiver disconnect also retains
  uncertainty; confirmed receiver exit closes this entire sender generation.

  Control setup grants the receiver credit before this sender accepts payloads.
  Payload submission has no RPC server or per-message remote task. The caller's
  result observes receiver append, suppression, rejection, or uncertainty. It does
  not acknowledge application consumption and is not the public publication receipt.
  """
  use GenServer, restart: :temporary
  @behaviour Jido.Cluster.Federation.Transport

  alias Jido.Cluster.Federation.{Envelope, Gate, Limits}
  alias Jido.Cluster.Federation.Transport.Receiver

  @doc "Starts one bounded sender after the receiver grants its exact process a credit."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns a local caller handle with direct admission capacity."
  @spec endpoint(pid()) :: map()
  def endpoint(sender), do: GenServer.call(sender, :endpoint)

  @doc "Admits and sends one envelope, or rejects before placing its payload in a mailbox."
  @spec transmit(map(), Envelope.t()) :: {:ok, :appended | :duplicate} | {:error, term()}
  @impl Jido.Cluster.Federation.Transport
  def transmit(endpoint, envelope) do
    with {:ok, _} <- Envelope.validate(envelope, endpoint.scope, endpoint.types, endpoint.limits),
         {:ok, permit} <- Gate.reserve(endpoint.gate, Envelope.bytes(envelope)) do
      GenServer.call(endpoint.pid, {:transmit, permit, envelope}, :infinity)
    end
  catch
    :exit, _ -> {:error, :sender_unavailable}
  end

  @doc "Reports credit use and current transport health without payload values."
  @spec status(pid()) :: map()
  def status(sender), do: GenServer.call(sender, :status)

  @impl true
  def init(opts) do
    receiver = Keyword.fetch!(opts, :receiver)
    timeout = Keyword.get(opts, :ack_timeout, 5000)

    with true <- is_integer(timeout) and timeout in 1..60_000,
         %Limits{} = limits <- receiver.limits,
         {:ok, ^limits} <- Limits.new(Map.to_list(Map.from_struct(limits))),
         {:ok, credit} <- Receiver.open(receiver.pid) do
      gate = Gate.new(%{limits | outbound_slots: 1, outbound_bytes: limits.max_envelope_bytes}, :outbound)

      {:ok,
       %{
         receiver: receiver,
         credit: credit,
         gate: gate,
         timeout: timeout,
         monitor: Process.monitor(receiver.pid),
         pending: nil,
         health: :healthy,
         acknowledged: 0,
         uncertain: 0,
         rejected: 0
       }}
    else
      false -> {:stop, :invalid_ack_timeout}
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :invalid_receiver}
    end
  catch
    :exit, reason -> {:stop, {:receiver_unavailable, reason}}
  end

  @impl true
  def handle_call(:endpoint, _, state) do
    endpoint = state.receiver |> Map.take([:scope, :types, :limits]) |> Map.merge(%{pid: self(), gate: state.gate})
    {:reply, endpoint, state}
  end

  def handle_call(:status, _, state) do
    result = Map.take(state, [:health, :acknowledged, :uncertain, :rejected])
    {:reply, Map.merge(result, %{pending: state.pending != nil, capacity: Gate.status(state.gate)}), state}
  end

  def handle_call({:transmit, permit, envelope}, from, %{pending: nil} = state) do
    transmission = make_ref()
    message = {:cluster_federation, state.credit, transmission, self(), envelope}

    case Process.send(state.receiver.pid, message, [:nosuspend, :noconnect]) do
      :ok ->
        timer = Process.send_after(self(), {:ack_timeout, transmission}, state.timeout)
        pending = %{id: transmission, permit: permit, from: from, timer: timer}
        {:noreply, %{state | pending: pending}}

      reason ->
        :ok = Gate.release(state.gate, permit)
        {:reply, {:error, reason}, %{state | health: :degraded, rejected: state.rejected + 1}}
    end
  end

  @impl true
  def handle_info(
        {:cluster_federation_ack, credit, id, result},
        %{credit: credit, pending: %{id: id} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(state.monitor, [:flush])
    state = %{state | monitor: Process.monitor(state.receiver.pid)}
    :ok = Gate.release(state.gate, pending.permit)
    if pending.from, do: GenServer.reply(pending.from, result)
    {:noreply, %{state | pending: nil, health: :healthy, acknowledged: state.acknowledged + 1}}
  end

  def handle_info({:ack_timeout, id}, %{pending: %{id: id}} = state),
    do: {:noreply, uncertain(state, :ack_timeout)}

  def handle_info({:DOWN, monitor, :process, _, :noconnection}, %{monitor: monitor} = state),
    do: {:noreply, uncertain(state, :noconnection)}

  def handle_info({:DOWN, monitor, :process, _, reason}, %{monitor: monitor} = state) do
    state = uncertain(state, {:receiver_down, reason})
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp uncertain(%{pending: %{from: from} = pending} = state, reason) when not is_nil(from) do
    GenServer.reply(from, {:error, reason})
    %{state | pending: %{pending | from: nil}, health: :uncertain, uncertain: state.uncertain + 1}
  end

  defp uncertain(state, _), do: %{state | health: :uncertain}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, Map.take(status.state, [:health, :acknowledged, :uncertain, :rejected]))
    |> Map.put(:message, :payload_redacted)
    |> Map.put(:log, [])
  end
end
