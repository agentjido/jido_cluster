defmodule JidoCluster.Examples.Support.JournalReplyLoss do
  @moduledoc false
  use GenServer
  alias Jido.Cluster
  alias Jido.Cluster.Instance
  @behaviour Jido.Persistence.Adapter

  def start_link(adapter), do: GenServer.start_link(__MODULE__, adapter)
  def lose_next(server), do: GenServer.call(server, :lose_next)
  def hold_next(server), do: GenServer.call(server, :hold_next)
  def waiting(server), do: GenServer.call(server, :waiting)
  def release(server), do: GenServer.call(server, :release)
  def lose_when(server, path, expected), do: GenServer.call(server, {:lose_when, path, expected})

  @impl GenServer
  def init(adapter), do: {:ok, %{adapter: adapter, mode: :normal, waiting: nil, trigger: nil}}

  @impl Jido.Persistence.Adapter
  def validate_options(opts), do: if(is_pid(opts[:server]), do: :ok, else: {:error, :invalid_server})

  @impl Jido.Persistence.Adapter
  def get(key, opts), do: GenServer.call(opts[:server], {:get, key}, 15_000)

  @impl Jido.Persistence.Adapter
  def compare_and_swap(key, expected, value, opts) do
    case GenServer.call(opts[:server], {:cas, key, expected, value}, 15_000) do
      :hold -> GenServer.call(opts[:server], :wait, 15_000)
      result -> result
    end
  end

  def start_drain(service, source, token) do
    supervisor = Instance.name(service, Operations)
    Task.Supervisor.start_child(supervisor, fn -> Cluster.drain(service, source, request_id: token) end)
  end

  @impl GenServer
  def handle_call(:lose_next, _from, state), do: {:reply, :ok, %{state | mode: :lose}}
  def handle_call(:hold_next, _from, state), do: {:reply, :ok, %{state | mode: :hold}}
  def handle_call(:waiting, _from, state), do: {:reply, state.waiting != nil, state}

  def handle_call({:lose_when, path, expected}, _from, state),
    do: {:reply, :ok, %{state | trigger: {path, expected}}}

  def handle_call(:wait, from, state), do: {:noreply, %{state | waiting: from}}

  def handle_call(:release, _from, state) do
    if state.waiting, do: GenServer.reply(state.waiting, :ok)
    {:reply, :ok, %{state | waiting: nil}}
  end

  def handle_call({:get, key}, _from, %{adapter: {module, opts}} = state),
    do: {:reply, module.get(key, opts), state}

  def handle_call({:cas, key, expected, value}, _from, %{adapter: {module, opts}} = state) do
    result = module.compare_and_swap(key, expected, value, opts)
    triggered = matches?(value, state.trigger)
    mode = if triggered, do: :lose, else: state.mode

    reply =
      case {result, mode} do
        {:ok, :lose} -> {:error, :timeout}
        {:ok, :hold} -> :hold
        _ -> result
      end

    {:reply, reply, %{state | mode: :normal, trigger: if(triggered, do: nil, else: state.trigger)}}
  end

  defp matches?(_, nil), do: false
  defp matches?(bytes, {path, expected}), do: at_path(Jason.decode!(bytes), path) == expected
  defp at_path(value, []), do: value
  defp at_path(value, [index | rest]) when is_list(value), do: at_path(Enum.at(value, index), rest)
  defp at_path(value, [key | rest]) when is_map(value), do: at_path(Map.get(value, key), rest)
  defp at_path(_, _), do: nil
end
