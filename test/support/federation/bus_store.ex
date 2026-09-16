defmodule JidoCluster.Test.Federation.BusStore do
  @moduledoc false
  @behaviour Jido.Signal.Bus.Store
  alias Jido.Signal.Bus.Store.Memory

  defmodule Control do
    @moduledoc false
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, {:control, opts})
    def hold(server, observer), do: GenServer.call(server, {:mode, {:hold, observer}})
    def reject(server), do: GenServer.call(server, {:mode, :reject})
    def release(server), do: GenServer.call(server, :release)

    @impl GenServer
    def init({:control, _}), do: {:ok, %{mode: :normal, pending: nil}}

    @impl GenServer
    def handle_call({:mode, mode}, _, state), do: {:reply, :ok, %{state | mode: mode}}

    def handle_call(:append, from, %{mode: {:hold, observer}} = state) do
      if is_pid(observer), do: send(observer, {:append_waiting, self()})
      {:noreply, %{state | mode: :normal, pending: from}}
    end

    def handle_call(:append, _, %{mode: :reject} = state),
      do: {:reply, {:error, :test_rejection}, %{state | mode: :normal}}

    def handle_call(:append, _, state), do: {:reply, :ok, state}

    def handle_call(:release, _, %{pending: pending} = state) do
      GenServer.reply(pending, :ok)
      {:reply, :ok, %{state | pending: nil}}
    end
  end

  @impl Jido.Signal.Bus.Store
  def init(opts) do
    {:ok, memory} = Memory.init(max_records: 64)
    {:ok, %{memory: memory, control: Keyword.fetch!(opts, :control)}}
  end

  @impl Jido.Signal.Bus.Store
  def append(records, state) do
    with :ok <- GenServer.call(state.control, :append, :infinity),
         {:ok, memory} <- Memory.append(records, state.memory),
         do: {:ok, %{state | memory: memory}}
  end

  @impl Jido.Signal.Bus.Store
  def read(opts, state), do: Memory.read(opts, state.memory)
  @impl Jido.Signal.Bus.Store
  def latest_cursor(state), do: Memory.latest_cursor(state.memory)
  @impl Jido.Signal.Bus.Store
  def list_subscriptions(state), do: Memory.list_subscriptions(state.memory)
  @impl Jido.Signal.Bus.Store
  def put_subscription(value, state) do
    with {:ok, memory} <- Memory.put_subscription(value, state.memory), do: {:ok, %{state | memory: memory}}
  end

  @impl Jido.Signal.Bus.Store
  def delete_subscription(value, state) do
    with {:ok, memory} <- Memory.delete_subscription(value, state.memory), do: {:ok, %{state | memory: memory}}
  end
end
