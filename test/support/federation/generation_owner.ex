defmodule JidoCluster.Test.Federation.GenerationOwner do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.Mirror

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def activation(owner), do: GenServer.call(owner, :activation)
  def close(owner, host, revision), do: GenServer.call(owner, {:close, host, revision})
  def prepare(owner, host, revision), do: GenServer.call(owner, {:prepare, host, revision})
  def finish(owner), do: GenServer.call(owner, :finish, 15_000)

  @impl true
  def init(opts) do
    activation = Activation.new({Keyword.fetch!(opts, :namespace), Jido.generate_id()}, "generation")
    :ok = Activation.claim(activation, self())
    {:ok, %{activation: activation, jido: Keyword.fetch!(opts, :jido)}}
  end

  @impl true
  def handle_call(:activation, _, state), do: {:reply, state.activation, state}

  def handle_call({:close, host, revision}, _, state),
    do: {:reply, Activation.close_resource(state.activation, self(), host, "events", revision), state}

  def handle_call({:prepare, host, revision}, _, state),
    do: {:reply, Activation.prepare_resource(state.activation, self(), host, "events", revision), state}

  def handle_call(:finish, _, state) do
    result =
      with :ok <- Activation.close(state.activation, self()),
           :ok <- Mirror.cleanup(state.jido, state.activation, self()),
           do: Activation.settle(state.activation, self())

    {:reply, result, state}
  end
end
