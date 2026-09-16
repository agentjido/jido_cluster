defmodule JidoCluster.Examples.Support.StartBarrier do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(_), do: {:ok, %{open: false, waiting: [], arrivals: 0}}
  def handle_call(:arrive, _from, %{open: true} = state), do: {:reply, :ok, state}

  def handle_call(:arrive, from, state),
    do: {:noreply, %{state | waiting: [from | state.waiting], arrivals: state.arrivals + 1}}

  def handle_call(:status, _from, state),
    do: {:reply, %{arrivals: state.arrivals, waiting: length(state.waiting)}, state}

  def handle_call(:release, _from, state) do
    for from <- state.waiting, do: GenServer.reply(from, :ok)
    {:reply, :ok, %{state | open: true, waiting: []}}
  end
end

defmodule JidoCluster.Examples.Support.StartBarrier.Persistence do
  @moduledoc false
  @behaviour Jido.Persistence.Adapter
  alias Jido.Persistence.Mnesia

  @impl true
  defdelegate validate_options(opts), to: Mnesia
  @impl true
  def get(key, opts) do
    # Hold at storage read, outside domain state and Signals. The call has a
    # finite deadline; peer cleanup terminates the fixture if an assertion fails.
    if String.starts_with?(key, "jido:agent:"),
      do: GenServer.call(JidoCluster.Examples.Support.StartBarrier, :arrive, 8_000)

    Mnesia.get(key, opts)
  end

  @impl true
  defdelegate compare_and_swap(key, expected, value, opts), to: Mnesia
end
