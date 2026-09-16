defmodule JidoCluster.Test.MovementBarrier do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    id = {__MODULE__, self()}
    :ok = :telemetry.attach(id, [:jido, :cluster, :placement, :ready], &__MODULE__.hold/4, self())
    {:ok, %{handler: id, waiting: []}}
  end

  def hold(_event, _measurements, metadata, server),
    do: GenServer.call(server, {:arrive, self(), metadata}, 15_000)

  def handle_call({:arrive, task, metadata}, from, state),
    do: {:noreply, %{state | waiting: [{task, metadata, from} | state.waiting]}}

  def handle_call(:status, _from, state),
    do: {:reply, Enum.map(state.waiting, fn {task, metadata, _} -> %{task: task, metadata: metadata} end), state}

  def handle_call(:release, _from, state) do
    for {_, _, from} <- state.waiting, do: GenServer.reply(from, :ok)
    {:reply, :ok, %{state | waiting: []}}
  end

  def terminate(_, state), do: :telemetry.detach(state.handler)
end
