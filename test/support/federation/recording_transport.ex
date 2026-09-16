defmodule JidoCluster.Test.Federation.RecordingTransport do
  @moduledoc false
  use GenServer
  @behaviour Jido.Cluster.Federation.Transport
  alias Jido.Cluster.Federation.{Envelope, Gate, Limits}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def endpoint(server), do: GenServer.call(server, :endpoint)
  def hold(server), do: GenServer.call(server, {:mode, :hold})
  def mode(server, mode), do: GenServer.call(server, {:mode, mode})
  def exports(server), do: GenServer.call(server, :exports)
  def callers(server), do: GenServer.call(server, :callers)
  def pending(server), do: GenServer.call(server, :pending)
  def release(server, result), do: GenServer.call(server, {:release, result})

  @impl Jido.Cluster.Federation.Transport
  def transmit(handle, envelope) do
    with {:ok, permit} <- Gate.reserve(handle.gate, Envelope.bytes(envelope)) do
      case GenServer.call(handle.pid, {:transmit, permit, envelope}, :infinity) do
        :raise -> raise "controlled transport failure"
        result -> result
      end
    end
  end

  @impl GenServer
  def init(_) do
    {:ok, limits} = Limits.new([])
    {:ok, %{gate: Gate.new(limits, :outbound), mode: :normal, exports: [], pending: []}}
  end

  @impl GenServer
  def handle_call(:endpoint, _, state), do: {:reply, %{pid: self(), gate: state.gate}, state}
  def handle_call(:exports, _, state), do: {:reply, Enum.reverse(state.exports), state}
  def handle_call(:callers, _, state), do: {:reply, Enum.map(state.pending, fn {{pid, _}, _} -> pid end), state}
  def handle_call(:pending, _, state), do: {:reply, length(state.pending), state}
  def handle_call({:mode, mode}, _, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call({:release, result}, _, state) do
    for {from, permit} <- state.pending do
      :ok = Gate.release(state.gate, permit)
      GenServer.reply(from, result)
    end

    {:reply, :ok, %{state | pending: [], mode: :normal}}
  end

  def handle_call({:transmit, permit, envelope}, from, state) do
    state = %{state | exports: [envelope | state.exports]}

    if state.mode == :hold do
      {:noreply, %{state | pending: [{from, permit} | state.pending]}}
    else
      :ok = Gate.release(state.gate, permit)
      result = if state.mode == :normal, do: {:ok, :appended}, else: state.mode
      {:reply, result, state}
    end
  end
end
