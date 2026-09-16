defmodule JidoCluster.Test.DockerReplyLoss do
  @moduledoc false
  use GenServer
  @behaviour Jido.Cluster.HostProvider
  alias Jido.Cluster.HostProvider.Docker

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  def steps(server), do: GenServer.call(server, :steps)
  def calls(server), do: GenServer.call(server, :calls)

  @impl GenServer
  def init(_), do: {:ok, %{lose: true, steps: %{}, calls: []}}

  @impl Jido.Cluster.HostProvider
  def validate_options(opts) do
    if is_pid(opts[:server]), do: Docker.validate_options(opts[:docker]), else: {:error, :invalid_server}
  end

  @impl Jido.Cluster.HostProvider
  def acquire(step, opts) do
    lose? = GenServer.call(opts[:server], {:acquire, step})

    case Docker.acquire(step, opts[:docker]) do
      {:ok, _} when lose? -> {:error, {:indeterminate, :withheld_acquire_reply}}
      result -> result
    end
  end

  @impl Jido.Cluster.HostProvider
  def inspect(step, opts) do
    :ok = GenServer.call(opts[:server], {:observe, :inspect, step})
    Docker.inspect(step, opts[:docker])
  end

  @impl Jido.Cluster.HostProvider
  def release(resource, opts) do
    :ok = GenServer.call(opts[:server], {:observe, :release, resource})
    Docker.release(resource, opts[:docker])
  end

  @impl Jido.Cluster.HostProvider
  def discover(scope, limit, opts), do: Docker.discover(scope, limit, opts[:docker])

  @impl GenServer
  def handle_call(:steps, _, state), do: {:reply, Map.values(state.steps), state}
  def handle_call(:calls, _, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:acquire, step}, _, state) do
    next = %{state | lose: false, steps: Map.put(state.steps, step.id, step), calls: [{:acquire, step} | state.calls]}
    {:reply, state.lose, next}
  end

  def handle_call({:observe, action, value}, _, state),
    do: {:reply, :ok, %{state | calls: [{action, value} | state.calls]}}
end
