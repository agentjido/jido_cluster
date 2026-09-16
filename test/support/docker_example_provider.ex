defmodule JidoCluster.Test.DockerExampleProvider do
  @moduledoc false
  use GenServer
  @behaviour Jido.Cluster.HostProvider
  alias Jido.Cluster.HostProvider.Docker

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  def steps(server), do: GenServer.call(server, :steps)
  def calls(server), do: GenServer.call(server, :calls)

  def mode(server, mode) when mode in [:normal, :lose_acquire_reply, :inspect_unavailable],
    do: GenServer.call(server, {:mode, mode})

  @impl GenServer
  def init(_), do: {:ok, %{steps: %{}, calls: [], mode: :normal}}

  @impl Jido.Cluster.HostProvider
  def validate_options(opts) do
    if is_pid(opts[:server]), do: Docker.validate_options(opts[:docker]), else: {:error, :invalid_server}
  end

  @impl Jido.Cluster.HostProvider
  def acquire(step, opts) do
    mode = GenServer.call(opts[:server], {:effect, :acquire, step})

    case Docker.acquire(step, opts[:docker]) do
      {:ok, _} when mode == :lose_acquire_reply -> {:error, {:indeterminate, :withheld_acquire_reply}}
      result -> result
    end
  end

  @impl Jido.Cluster.HostProvider
  def inspect(step, opts) do
    case GenServer.call(opts[:server], {:effect, :inspect, step}) do
      :inspect_unavailable -> {:error, :unavailable}
      _ -> Docker.inspect(step, opts[:docker])
    end
  end

  @impl Jido.Cluster.HostProvider
  def release(resource, opts) do
    GenServer.call(opts[:server], {:effect, :release, resource})
    Docker.release(resource, opts[:docker])
  end

  @impl Jido.Cluster.HostProvider
  def discover(scope, limit, opts), do: Docker.discover(scope, limit, opts[:docker])

  @impl GenServer
  def handle_call(:steps, _, state), do: {:reply, Map.values(state.steps), state}
  def handle_call(:calls, _, state), do: {:reply, Enum.reverse(state.calls), state}
  def handle_call({:mode, mode}, _, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call({:effect, action, value}, _, state) do
    steps = if action == :acquire, do: Map.put(state.steps, value.id, value), else: state.steps
    consumed = {action, state.mode} in [{:acquire, :lose_acquire_reply}, {:inspect, :inspect_unavailable}]

    next = %{
      state
      | steps: steps,
        calls: [{action, value} | state.calls],
        mode: if(consumed, do: :normal, else: state.mode)
    }

    {:reply, state.mode, next}
  end
end
