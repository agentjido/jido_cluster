defmodule JidoCluster.Test.JournalAdapter do
  @moduledoc false
  use GenServer
  alias Jido.Cluster
  alias Jido.Cluster.Instance
  @behaviour Jido.Persistence.Adapter

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl GenServer
  def init(opts),
    do:
      {:ok,
       %{
         records: %{},
         mode: :normal,
         trigger: nil,
         tokens: Keyword.get(opts, :tokens, false),
         writes: [],
         pending: nil,
         waiting: nil
       }}

  def mode(server, mode), do: GenServer.call(server, {:mode, mode})
  def when_write(server, predicate, mode), do: GenServer.call(server, {:when_write, predicate, mode})
  def waiting(server), do: GenServer.call(server, :waiting)
  def release(server), do: GenServer.call(server, :release)

  def start_drain(service, source, token) do
    supervisor = Instance.name(service, Operations)
    Task.Supervisor.start_child(supervisor, fn -> Cluster.drain(service, source, request_id: token) end)
  end

  def when_path(server, path, expected, mode) do
    when_write(server, fn bytes -> read_path(Jason.decode!(bytes), path) == expected end, mode)
  end

  defp read_path(value, []), do: value

  defp read_path(value, [index | rest]) when is_list(value) and is_integer(index),
    do: read_path(Enum.at(value, index), rest)

  defp read_path(value, [key | rest]) when is_map(value), do: read_path(Map.get(value, key), rest)
  defp read_path(_, _), do: nil
  def writes(server), do: GenServer.call(server, :writes)
  def finish_delayed(server), do: GenServer.call(server, :finish_delayed)

  @impl Jido.Persistence.Adapter
  def validate_options(opts), do: if(is_pid(opts[:server]), do: :ok, else: {:error, :invalid_server})

  @impl Jido.Persistence.Adapter
  def get(key, opts), do: GenServer.call(opts[:server], {:get, key})

  @impl Jido.Persistence.Adapter
  def compare_and_swap(key, expected, value, opts) do
    case GenServer.call(opts[:server], {:cas, key, expected, value}) do
      :manual_hold ->
        GenServer.call(opts[:server], :wait, 10_000)

      {:raise, reason} ->
        raise reason

      {:throw, reason} ->
        throw(reason)

      {:exit, reason} ->
        exit(reason)

      {:hold, observer, ref} ->
        send(observer, {:journal_written, self(), ref})

        receive do
          {:release, ^ref} -> :ok
        after
          10_000 -> {:error, :timeout}
        end

      result ->
        result
    end
  end

  @impl GenServer
  def handle_call({:mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call({:when_write, predicate, mode}, _from, state),
    do: {:reply, :ok, %{state | trigger: {predicate, mode}}}

  def handle_call(:writes, _from, state), do: {:reply, Enum.reverse(state.writes), state}
  def handle_call(:waiting, _from, state), do: {:reply, state.waiting != nil, state}
  def handle_call(:wait, from, state), do: {:noreply, %{state | waiting: from}}

  def handle_call(:release, _from, state) do
    if state.waiting, do: GenServer.reply(state.waiting, :ok)
    {:reply, :ok, %{state | waiting: nil}}
  end

  def handle_call(:finish_delayed, _from, %{pending: {key, expected, value}} = state) do
    state = %{state | pending: nil}

    if matches?(Map.get(state.records, key), expected),
      do: apply_write(state, key, value),
      else: {:reply, {:error, :conflict}, state}
  end

  def handle_call({:get, key}, _from, state) do
    result =
      case Map.get(state.records, key) do
        nil -> {:error, :not_found}
        {value, token} when state.tokens -> {:ok, value, token}
        {value, _token} -> {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:cas, key, expected, value}, _from, state) do
    state = %{state | writes: [{key, expected, value} | state.writes]}
    state = trigger(state, value)
    current = Map.get(state.records, key)

    cond do
      state.mode == :delay -> {:reply, {:error, :timeout}, %{state | mode: :normal, pending: {key, expected, value}}}
      matches?(current, expected) -> apply_write(state, key, value)
      true -> {:reply, {:error, :conflict}, state}
    end
  end

  defp trigger(%{trigger: nil} = state, _), do: state

  defp trigger(%{trigger: {predicate, mode}} = state, value) do
    if predicate.(value), do: %{state | mode: mode, trigger: nil}, else: state
  end

  defp apply_write(%{mode: {:return, result}} = state, _key, _value),
    do: {:reply, result, %{state | mode: :normal}}

  defp apply_write(state, key, value) do
    result =
      case state.mode do
        :manual_hold -> :manual_hold
        :commit_then_lose -> {:error, :timeout}
        :commit_then_indeterminate -> {:error, :indeterminate}
        {:hold, observer} -> {:hold, observer, make_ref()}
        _ -> :ok
      end

    record = {value, Jido.generate_id()}
    {:reply, result, %{state | records: Map.put(state.records, key, record), mode: :normal}}
  end

  defp matches?(nil, :not_found), do: true
  defp matches?({_value, token}, {:token, token}), do: true
  defp matches?({value, _token}, value), do: true
  defp matches?(_, _), do: false
end
