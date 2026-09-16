defmodule JidoCluster.Examples.Support.LocationVisibilityBarrier do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def status(server), do: GenServer.call(server, :status)
  def release(server), do: GenServer.call(server, :release)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    handler = {__MODULE__, self()}
    match = {Jido.namespace(opts[:jido]), opts[:id], self()}
    :ok = :telemetry.attach(handler, [:jido, :agent, :lifecycle, :start], &__MODULE__.hold/4, match)
    {:ok, %{handler: handler, waiting: [], arrivals: 0, open: false}}
  end

  def hold(_, _, %{agent_namespace: namespace, agent_id: id, operation: operation}, {namespace, id, server})
      when operation in [:activate, :thaw],
      do: GenServer.call(server, {:arrive, self()}, 10_000)

  def hold(_, _, _, _), do: :ok

  @impl true
  def handle_call({:arrive, _}, _, %{open: true} = state), do: {:reply, :ok, state}

  def handle_call({:arrive, agent}, from, state),
    do: {:noreply, %{state | arrivals: state.arrivals + 1, waiting: [{agent, from} | state.waiting]}}

  def handle_call(:status, _, state),
    do: {:reply, %{arrivals: state.arrivals, agents: Enum.map(state.waiting, &elem(&1, 0))}, state}

  def handle_call(:release, _, state) do
    :ok = :telemetry.detach(state.handler)
    for {_, from} <- state.waiting, do: GenServer.reply(from, :ok)
    {:reply, :ok, %{state | waiting: [], open: true}}
  end

  @impl true
  def terminate(_, state), do: :telemetry.detach(state.handler)
end
