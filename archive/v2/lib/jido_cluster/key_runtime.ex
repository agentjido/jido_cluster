defmodule JidoCluster.KeyRuntime do
  @moduledoc false

  use GenServer

  alias Jido.AgentServer
  alias Jido.Cluster.{Ownership, Placement, RuntimeSnapshot, RuntimeSummary}
  alias Jido.Cluster.KeyRuntime.State
  alias JidoCluster.Internal.{InstanceManagerConfig, Remote}
  alias JidoCluster.Topology

  @default_timeout_ms 5_000

  @type state :: State.t()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    manager = Keyword.fetch!(opts, :manager)
    key = Keyword.fetch!(opts, :key)

    %{
      id: {__MODULE__, manager, key},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    manager = Keyword.fetch!(opts, :manager)
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: via(manager, key))
  end

  @spec via(term(), term()) :: {:via, Registry, {atom(), term()}}
  def via(manager, key), do: {:via, Registry, {registry_name(manager), key}}

  @spec registry_name(term()) :: atom()
  def registry_name(manager), do: :"#{__MODULE__}.Registry.#{manager}"

  @spec dynamic_supervisor_name(term()) :: atom()
  def dynamic_supervisor_name(manager), do: :"#{__MODULE__}.DynamicSupervisor.#{manager}"

  @spec ensure_replica_set(term(), term(), keyword(), timeout()) ::
          {:ok, %{primary: node(), standby: node() | nil}} | {:error, term()}
  def ensure_replica_set(manager, key, opts \\ [], timeout \\ @default_timeout_ms) do
    nodes = Topology.connected_nodes()
    placement_count = placement_count(manager, nodes)
    %Placement{primary: primary, standby: standby} = Topology.placement(manager, key, nodes, placement_count)

    base = %{
      primary: primary,
      standby: standby,
      epoch: 0,
      seq: 0,
      initial_state: Keyword.get(opts, :initial_state, %{})
    }

    with {:ok, _} <- ensure_remote_runtime(primary, manager, key, Map.put(base, :role, :primary), timeout),
         {:ok, _} <- maybe_ensure_remote_runtime(standby, manager, key, Map.put(base, :role, :standby), timeout),
         {:ok, :ok} <- maybe_sync(primary, standby, manager, key, timeout),
         {:ok, :ok} <- maybe_reconcile_replica_set(primary, standby, manager, key, timeout) do
      {:ok, %{primary: primary, standby: standby}}
    end
  end

  @spec primary_pid(term(), term()) :: {:ok, pid()} | :error
  def primary_pid(manager, key) do
    case GenServer.whereis(via(manager, key)) do
      nil ->
        :error

      pid ->
        GenServer.call(pid, :primary_pid)
    end
  end

  @spec agent_snapshot(term(), term()) :: {:ok, map()} | {:error, term()}
  def agent_snapshot(manager, key) do
    case GenServer.whereis(via(manager, key)) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.call(pid, :agent_snapshot)
    end
  end

  @spec local_summary(term(), term()) :: RuntimeSummary.t() | nil
  def local_summary(manager, key) do
    case :persistent_term.get(summary_cache_key(manager, key), :undefined) do
      :undefined -> nil
      %RuntimeSummary{} = summary -> summary
      _ -> nil
    end
  end

  @spec local_keys(term()) :: [term()]
  def local_keys(manager) do
    registry = registry_name(manager)

    case Process.whereis(registry) do
      nil ->
        []

      _pid ->
        Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    end
  end

  @spec primary_keys(term()) :: [term()]
  def primary_keys(manager) do
    manager
    |> local_keys()
    |> Enum.filter(fn key ->
      case local_summary(manager, key) do
        %{role: :primary} -> true
        _ -> false
      end
    end)
  end

  @spec owner_node(term(), term(), timeout()) :: node()
  def owner_node(manager, key, timeout \\ @default_timeout_ms) do
    desired_primary = Topology.owner_node(manager, key, Topology.connected_nodes())

    summaries =
      Topology.connected_nodes()
      |> Enum.flat_map(fn node ->
        case Remote.rpc(node, __MODULE__, :local_summary, [manager, key], timeout) do
          {:ok, nil} -> []
          {:ok, %RuntimeSummary{} = summary} -> [summary]
          _ -> []
        end
      end)

    case summaries do
      [] ->
        desired_primary

      _ ->
        summaries
        |> Enum.max_by(fn summary ->
          {
            summary.epoch,
            summary.seq,
            if(summary.primary == desired_primary, do: 1, else: 0),
            if(summary.role == :primary, do: 1, else: 0)
          }
        end)
        |> Map.fetch!(:primary)
    end
  end

  @spec cluster_call(term(), term(), Jido.Signal.t(), timeout()) :: {:ok, struct()} | {:error, term()}
  def cluster_call(manager, key, signal, timeout \\ @default_timeout_ms) do
    owner = owner_node(manager, key, timeout)

    case Remote.rpc(owner, __MODULE__, :handle_signal, [manager, key, signal, timeout, :call], timeout + 1_000) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cluster_cast(term(), term(), Jido.Signal.t(), timeout()) :: :ok | {:error, term()}
  def cluster_cast(manager, key, signal, timeout \\ @default_timeout_ms) do
    owner = owner_node(manager, key, timeout)

    case Remote.rpc(owner, __MODULE__, :handle_signal, [manager, key, signal, timeout, :cast], timeout + 1_000) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec sync_standby(term(), term(), timeout()) :: :ok | {:error, term()}
  def sync_standby(manager, key, timeout \\ @default_timeout_ms) do
    case GenServer.whereis(via(manager, key)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:sync_standby, timeout}, timeout + 1_000)
    end
  end

  @spec handle_signal(term(), term(), Jido.Signal.t(), timeout(), :call | :cast) ::
          {:ok, struct()} | :ok | {:error, term()}
  def handle_signal(manager, key, signal, timeout, mode) when mode in [:call, :cast] do
    GenServer.call(via(manager, key), {:handle_signal, signal, timeout, mode}, timeout + 1_000)
  end

  @spec handoff(term(), term(), node(), timeout()) :: :ok | {:error, term()}
  def handoff(manager, key, target, timeout \\ @default_timeout_ms) do
    GenServer.call(via(manager, key), {:handoff, target, timeout}, timeout + 2_000)
  end

  @spec stop_cluster(term(), term(), timeout()) :: :ok | {:error, term()}
  def stop_cluster(manager, key, timeout \\ @default_timeout_ms) do
    owner = owner_node(manager, key, timeout)

    case Remote.rpc(owner, __MODULE__, :stop_local, [manager, key], timeout) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop_local(term(), term()) :: :ok | {:error, :not_found}
  def stop_local(manager, key) do
    case GenServer.whereis(via(manager, key)) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.call(pid, :stop_local)
    end
  end

  @spec adopt_runtime(RuntimeSnapshot.t()) :: :ok | {:error, term()}
  def adopt_runtime(%RuntimeSnapshot{manager: manager, key: key} = snapshot) do
    GenServer.call(via(manager, key), {:adopt_runtime, snapshot})
  end

  @spec ensure_local(term(), term(), map()) :: {:ok, pid()} | {:error, term()}
  def ensure_local(manager, key, opts) when is_map(opts) do
    case GenServer.whereis(via(manager, key)) do
      nil ->
        start_local_runtime(manager, key, opts)

      pid ->
        case maybe_restart_stale_runtime(manager, key, pid, opts) do
          {:restarted, pid} ->
            {:ok, pid}

          :continue ->
            case GenServer.call(pid, {:ensure, opts}) do
              :ok -> {:ok, pid}
              {:error, _} = error -> error
            end

          {:error, _} = error ->
            error
        end
    end
  end

  @impl true
  def init(opts) do
    :ok = :net_kernel.monitor_nodes(true)

    manager = Keyword.fetch!(opts, :manager)
    key = Keyword.fetch!(opts, :key)

    with {:ok, manager_config} <- InstanceManagerConfig.fetch(manager),
         {:ok, cluster_config} <- InstanceManagerConfig.fetch_cluster(manager) do
      state =
        State.new!(%{
          manager: manager,
          key: key,
          agent_module: Map.fetch!(manager_config, :agent),
          jido: Map.get(manager_config, :jido, Jido),
          agent_opts: Map.get(manager_config, :agent_opts, []),
          primary: Keyword.get(opts, :primary, Node.self()),
          standby: Keyword.get(opts, :standby),
          role: Keyword.get(opts, :role, :primary),
          epoch: Keyword.get(opts, :epoch, 0),
          seq: Keyword.get(opts, :seq, 0),
          promotion_timeout_ms: cluster_config.replication.promotion_timeout_ms,
          promotion_timer: nil,
          agent_pid: nil,
          initial_state: Keyword.get(opts, :initial_state, %{})
        })

      {:ok, state |> ensure_agent_started() |> publish_summary()}
    else
      :error -> {:stop, :manager_not_configured}
    end
  end

  @impl true
  def terminate(_reason, state) do
    clear_summary(state)
    :ok
  end

  @impl true
  def handle_call(:summary, _from, state) do
    {:reply, summary(state), state}
  end

  def handle_call(:primary_pid, _from, %{role: :primary, agent_pid: pid} = state) when is_pid(pid) do
    {:reply, {:ok, pid}, state}
  end

  def handle_call(:primary_pid, _from, state) do
    {:reply, :error, state}
  end

  def handle_call(:agent_snapshot, _from, %{agent_pid: pid} = state) when is_pid(pid) do
    {:reply, capture_agent_snapshot(pid), state}
  end

  def handle_call(:agent_snapshot, _from, state) do
    {:reply, {:error, :agent_not_started}, state}
  end

  def handle_call({:ensure, opts}, _from, state) do
    {:reply, :ok, ensure_runtime_state(state, opts)}
  end

  def handle_call({:sync_standby, timeout}, _from, state) do
    case do_sync_standby(state, timeout) do
      {:ok, new_state} -> {:reply, :ok, publish_summary(new_state)}
      {:error, reason, new_state} -> {:reply, {:error, reason}, publish_summary(new_state)}
    end
  end

  def handle_call({:handle_signal, signal, timeout, mode}, _from, %{role: :primary} = state) do
    case do_handle_signal(state, signal, timeout) do
      {:ok, agent, new_state} ->
        reply =
          case mode do
            :call -> {:ok, agent}
            :cast -> :ok
          end

        {:reply, reply, publish_summary(new_state)}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, publish_summary(new_state)}
    end
  end

  def handle_call({:handle_signal, _signal, _timeout, _mode}, _from, state) do
    {:reply, {:error, :not_primary}, state}
  end

  def handle_call({:handoff, target, timeout}, _from, %{role: :primary} = state) do
    case do_handoff(state, target, timeout) do
      {:ok, new_state} -> {:reply, :ok, publish_summary(new_state)}
      {:ok, :stop, new_state} -> {:stop, :normal, :ok, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, publish_summary(new_state)}
    end
  end

  def handle_call({:handoff, _target, _timeout}, _from, state) do
    {:reply, {:error, :not_primary}, state}
  end

  def handle_call({:adopt_runtime, %RuntimeSnapshot{} = snapshot}, _from, state) do
    new_state =
      state
      |> ensure_runtime_state(%{
        role: snapshot.cluster_role,
        primary: snapshot.primary,
        standby: snapshot.standby,
        epoch: snapshot.epoch,
        seq: snapshot.seq
      })
      |> apply_snapshot(snapshot)

    {:reply, :ok, publish_summary(new_state)}
  end

  def handle_call(:stop_local, _from, state) do
    {:stop, :normal, :ok, stop_local_agent(state)}
  end

  @impl true
  def handle_info({:nodedown, node}, %{role: :standby, primary: node} = state) do
    if is_nil(state.promotion_timer) do
      timer = Process.send_after(self(), :promote_after_timeout, state.promotion_timeout_ms)
      {:noreply, %{state | promotion_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodeup, _node}, state) do
    send(self(), :heal)
    {:noreply, clear_promotion_timer(state)}
  end

  def handle_info(:promote_after_timeout, %{role: :standby} = state) do
    if state.primary in Node.list() do
      {:noreply, %{state | promotion_timer: nil}}
    else
      {:noreply, promote_self(state)}
    end
  end

  def handle_info(:heal, state) do
    {:noreply, maybe_heal(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{agent_pid: pid} = state) do
    {:noreply, %{state | agent_pid: nil} |> publish_summary()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp summary(state) do
    ownership = ownership(state)

    RuntimeSummary.new!(
      manager: state.manager,
      key: state.key,
      node: Node.self(),
      agent_pid: state.agent_pid,
      role: ownership.role,
      epoch: ownership.epoch,
      seq: ownership.seq,
      primary: ownership.primary,
      standby: ownership.standby,
      status: ownership.status
    )
  end

  defp ownership(state) do
    Ownership.new!(
      manager: state.manager,
      key: state.key,
      epoch: state.epoch,
      seq: state.seq,
      primary: state.primary,
      standby: state.standby,
      role: state.role,
      status: ownership_status(state)
    )
  end

  defp ownership_status(%{role: :primary, agent_pid: pid}) when is_pid(pid), do: :owned
  defp ownership_status(%{role: :standby, agent_pid: pid}) when is_pid(pid), do: :standby
  defp ownership_status(%{role: :standby}), do: :standby
  defp ownership_status(_state), do: :starting

  defp summary_cache_key(manager, key), do: {__MODULE__, :summary, manager, key}

  defp build_runtime_snapshot(key, manager, epoch, seq, cluster_role, primary, standby, agent_snapshot) do
    RuntimeSnapshot.new!(
      manager: manager,
      key: key,
      epoch: epoch,
      seq: seq,
      agent_module: Map.get(agent_snapshot, :agent_module),
      cluster_role: cluster_role,
      primary: primary,
      standby: standby,
      agent_snapshot: agent_snapshot
    )
  end

  defp publish_summary(state) do
    :persistent_term.put(summary_cache_key(state.manager, state.key), summary(state))
    state
  end

  defp clear_summary(state) do
    :persistent_term.erase(summary_cache_key(state.manager, state.key))
    state
  end

  defp start_local_runtime(manager, key, opts) do
    child_opts =
      opts
      |> Map.put(:manager, manager)
      |> Map.put(:key, key)
      |> Map.to_list()

    case DynamicSupervisor.start_child(dynamic_supervisor_name(manager), {__MODULE__, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_restart_stale_runtime(manager, key, pid, opts) do
    current_epoch =
      case local_summary(manager, key) do
        %{epoch: epoch} when is_integer(epoch) -> epoch
        _ -> 0
      end

    requested_epoch = Map.get(opts, :epoch, current_epoch)

    if requested_epoch > current_epoch do
      case DynamicSupervisor.terminate_child(dynamic_supervisor_name(manager), pid) do
        :ok ->
          case start_local_runtime(manager, key, opts) do
            {:ok, new_pid} -> {:restarted, new_pid}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      :continue
    end
  end

  defp ensure_remote_runtime(nil, _manager, _key, _opts, _timeout), do: {:ok, nil}

  defp ensure_remote_runtime(node, manager, key, opts, timeout) do
    if node == Node.self() do
      ensure_local(manager, key, opts)
    else
      Remote.rpc(node, __MODULE__, :ensure_local, [manager, key, opts], timeout)
    end
  end

  defp maybe_ensure_remote_runtime(nil, _manager, _key, _opts, _timeout), do: {:ok, nil}

  defp maybe_ensure_remote_runtime(node, manager, key, opts, timeout),
    do: ensure_remote_runtime(node, manager, key, opts, timeout)

  defp maybe_sync(_primary, nil, _manager, _key, _timeout), do: {:ok, :ok}

  defp maybe_sync(primary, _standby, manager, key, timeout) do
    if primary == Node.self() do
      case sync_standby(manager, key, timeout) do
        :ok -> {:ok, :ok}
        {:error, reason} -> {:error, reason}
      end
    else
      Remote.rpc(primary, __MODULE__, :sync_standby, [manager, key, timeout], timeout)
    end
  end

  defp maybe_reconcile_replica_set(_primary, nil, _manager, _key, _timeout), do: {:ok, :ok}

  defp maybe_reconcile_replica_set(primary, standby, manager, key, timeout) do
    summaries =
      [primary, standby]
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn node, acc ->
        case fetch_remote_summary(node, manager, key, timeout) do
          nil -> acc
          summary -> Map.put(acc, node, summary)
        end
      end)

    case Map.values(summaries) do
      [%{epoch: left_epoch} = left, %{epoch: right_epoch} = right] when left_epoch != right_epoch ->
        if left_epoch > right_epoch do
          reconcile_with_winner(left, right, manager, key, timeout)
        else
          reconcile_with_winner(right, left, manager, key, timeout)
        end

      [%{} = left, %{} = right] ->
        maybe_reconcile_equal_epoch(left, right, primary, standby, manager, key, timeout)

      _ ->
        {:ok, :ok}
    end
  end

  defp maybe_reconcile_equal_epoch(left, right, desired_primary, desired_standby, manager, key, timeout) do
    if left.primary == right.primary and left.standby == right.standby and left.seq == right.seq do
      {:ok, :ok}
    else
      winner = pick_reconcile_winner(left, right, desired_primary, desired_standby)
      loser = if winner == left, do: right, else: left
      reconcile_with_winner(winner, loser, manager, key, timeout)
    end
  end

  defp pick_reconcile_winner(left, right, desired_primary, desired_standby) do
    Enum.max_by([left, right], fn summary ->
      {
        if(summary.primary == desired_primary, do: 1, else: 0),
        if(summary.standby == desired_standby, do: 1, else: 0),
        summary.seq,
        if(summary.node == summary.primary, do: 1, else: 0),
        if(summary.role == :primary, do: 1, else: 0)
      }
    end)
  end

  defp fetch_remote_summary(node, manager, key, timeout) do
    case Remote.rpc(node, __MODULE__, :local_summary, [manager, key], timeout) do
      {:ok, %RuntimeSummary{} = summary} -> summary
      _ -> nil
    end
  end

  defp placement_count(manager, nodes \\ Topology.connected_nodes()) do
    nodes
    |> length()
    |> min(replica_count(manager) + 1)
    |> max(1)
  end

  defp replica_count(manager) do
    case InstanceManagerConfig.fetch_cluster(manager) do
      {:ok, %{replication: %{replicas: replicas}}} when replicas in [0, 1] -> replicas
      _ -> 0
    end
  end

  defp reconcile_with_winner(winner, loser, manager, key, timeout) do
    winner_node = winner.primary
    loser_node = loser.node

    standby_node =
      if replica_count(manager) > 0 and loser_node != winner_node do
        loser_node
      end

    with {:ok, {:ok, agent_snapshot}} <- Remote.rpc(winner_node, __MODULE__, :agent_snapshot, [manager, key], timeout),
         winner_snapshot <-
           build_runtime_snapshot(
             key,
             manager,
             winner.epoch,
             winner.seq,
             :primary,
             winner_node,
             standby_node,
             agent_snapshot
           ),
         :ok <- reconcile_loser(loser_node, standby_node, manager, key, winner, winner_snapshot, timeout),
         {:ok, :ok} <-
           Remote.rpc(
             winner_node,
             __MODULE__,
             :adopt_runtime,
             [winner_snapshot],
             timeout
           ) do
      {:ok, :ok}
    else
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_reconcile_result, other}}
    end
  end

  defp reconcile_loser(loser_node, nil, manager, key, _winner, _winner_snapshot, timeout) do
    case Remote.rpc(loser_node, __MODULE__, :stop_local, [manager, key], timeout) do
      {:ok, :ok} -> :ok
      {:ok, {:error, :not_found}} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_loser(loser_node, standby_node, manager, key, winner, winner_snapshot, timeout) do
    with {:ok, _} <-
           ensure_remote_runtime(
             loser_node,
             manager,
             key,
             %{
               role: :standby,
               primary: winner.primary,
               standby: standby_node,
               epoch: winner.epoch,
               seq: winner.seq
             },
             timeout
           ),
         {:ok, :ok} <-
           Remote.rpc(
             loser_node,
             __MODULE__,
             :adopt_runtime,
             [RuntimeSnapshot.new!(Map.from_struct(winner_snapshot) |> Map.put(:cluster_role, :standby))],
             timeout
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_reconcile_loser_result, other}}
    end
  end

  defp ensure_runtime_state(state, opts) do
    requested_epoch = Map.get(opts, :epoch, state.epoch)
    next_role = Map.get(opts, :role, state.role)
    prior_primary = state.primary
    prior_epoch = state.epoch

    state =
      state
      |> Map.put(:primary, Map.get(opts, :primary, state.primary))
      |> Map.put(:standby, Map.get(opts, :standby, state.standby))
      |> Map.put(:epoch, max(state.epoch, requested_epoch))
      |> Map.put(:seq, max(state.seq, Map.get(opts, :seq, state.seq)))
      |> Map.put(:initial_state, Map.get(opts, :initial_state, state.initial_state))
      |> ensure_agent_started()

    cond do
      next_role == state.role ->
        publish_summary(state)

      implicit_role_change_allowed?(prior_primary, prior_epoch, requested_epoch) ->
        apply_implicit_role_change(state, next_role)

      true ->
        publish_summary(state)
    end
  end

  defp implicit_role_change_allowed?(prior_primary, prior_epoch, requested_epoch) do
    requested_epoch > prior_epoch or is_nil(prior_primary) or prior_primary not in Topology.connected_nodes()
  end

  defp apply_implicit_role_change(%{role: :standby} = state, :primary), do: promote_self(state)
  defp apply_implicit_role_change(state, next_role), do: set_local_role(state, next_role)

  defp do_handle_signal(state, signal, timeout) do
    with {:ok, agent} <- AgentServer.call(state.agent_pid, signal, timeout) do
      next_seq = state.seq + 1

      case do_sync_standby(state, timeout, next_seq) do
        {:ok, new_state} -> {:ok, agent, new_state}
        {:error, reason, new_state} -> {:error, {:replication_failed, reason}, new_state}
      end
    else
      {:error, _} = error ->
        {:error, reason} = error
        {:error, reason, state}
    end
  end

  defp do_sync_standby(state, timeout, next_seq \\ nil)

  defp do_sync_standby(%{standby: nil} = state, _timeout, next_seq) do
    {:ok, %{state | seq: next_seq || state.seq}}
  end

  defp do_sync_standby(state, timeout, next_seq) do
    if replica_count(state.manager) == 0 do
      {:ok, %{state | standby: nil, seq: next_seq || state.seq}}
    else
      do_sync_configured_standby(state, timeout, next_seq)
    end
  end

  defp do_sync_configured_standby(%{standby: standby} = state, timeout, next_seq) do
    if standby == Node.self() do
      {:ok, %{state | seq: next_seq || state.seq}}
    else
      with {:ok, agent_snapshot} <- capture_agent_snapshot(state.agent_pid),
           snapshot <-
             build_runtime_snapshot(
               state.key,
               state.manager,
               state.epoch,
               next_seq || state.seq,
               :standby,
               state.primary,
               state.standby,
               agent_snapshot
             ),
           {:ok, _} <-
             Remote.rpc(
               state.standby,
               __MODULE__,
               :ensure_local,
               [
                 state.manager,
                 state.key,
                 %{
                   role: :standby,
                   primary: state.primary,
                   standby: state.standby,
                   epoch: state.epoch,
                   seq: state.seq
                 }
               ],
               timeout
             ),
           {:ok, :ok} <- Remote.rpc(state.standby, __MODULE__, :adopt_runtime, [snapshot], timeout) do
        {:ok, %{state | seq: next_seq || state.seq}}
      else
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp do_handoff(state, target, timeout) do
    next_epoch = state.epoch + 1
    new_standby = if replica_count(state.manager) > 0, do: Node.self(), else: nil

    with {:ok, agent_snapshot} <- capture_agent_snapshot(state.agent_pid),
         target_snapshot <-
           build_runtime_snapshot(
             state.key,
             state.manager,
             next_epoch,
             state.seq,
             :primary,
             target,
             new_standby,
             agent_snapshot
           ),
         {:ok, _} <-
           ensure_remote_runtime(
             target,
             state.manager,
             state.key,
             %{
               role: :primary,
               primary: target,
               standby: new_standby,
               epoch: next_epoch,
               seq: state.seq
             },
             timeout
           ),
         {:ok, :ok} <- Remote.rpc(target, __MODULE__, :adopt_runtime, [target_snapshot], timeout) do
      maybe_keep_local_standby(state, target, new_standby, next_epoch, agent_snapshot)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp maybe_keep_local_standby(state, _target, nil, _next_epoch, _agent_snapshot) do
    {:ok, :stop, stop_local_agent(%{state | primary: nil, standby: nil})}
  end

  defp maybe_keep_local_standby(state, target, new_standby, next_epoch, agent_snapshot) do
    local_snapshot =
      build_runtime_snapshot(
        state.key,
        state.manager,
        next_epoch,
        state.seq,
        :standby,
        target,
        new_standby,
        agent_snapshot
      )

    {:ok, apply_snapshot(state, local_snapshot)}
  end

  defp maybe_heal(%{primary: primary, standby: standby} = state) do
    desired =
      Topology.replica_nodes(state.manager, state.key, Topology.connected_nodes(), placement_count(state.manager))

    desired_primary = hd(desired)
    desired_standby = Enum.at(desired, 1)
    peer = Enum.find([primary, standby, desired_primary, desired_standby], &(&1 && &1 != Node.self()))

    case peer && Remote.rpc(peer, __MODULE__, :local_summary, [state.manager, state.key], @default_timeout_ms) do
      {:ok, nil} ->
        publish_summary(state)

      {:ok, remote} ->
        heal_with_remote(state, remote, desired_primary, desired_standby, peer) |> publish_summary()

      _ ->
        %{state | primary: if(state.role == :primary, do: Node.self(), else: state.primary), standby: nil}
        |> publish_summary()
    end
  end

  defp heal_with_remote(state, remote, desired_primary, desired_standby, peer) do
    cond do
      remote.epoch > state.epoch ->
        sync_from_remote(state, remote, peer)

      remote.epoch < state.epoch and state.role == :primary ->
        maybe_push_primary_state(state, peer, desired_primary, desired_standby)

      remote.epoch == state.epoch and state.role == :primary and desired_primary != Node.self() ->
        case do_handoff(%{state | standby: peer}, desired_primary, @default_timeout_ms) do
          {:ok, new_state} -> new_state
          _ -> state
        end

      remote.epoch == state.epoch and state.role == :standby and desired_primary == Node.self() ->
        promote_self(state)

      remote.epoch == state.epoch and state.role == :standby ->
        sync_from_remote(state, remote, peer)

      true ->
        state
    end
  end

  defp sync_from_remote(state, remote, peer) do
    case Remote.rpc(peer, __MODULE__, :agent_snapshot, [state.manager, state.key], @default_timeout_ms) do
      {:ok, {:ok, agent_snapshot}} ->
        snapshot =
          build_runtime_snapshot(
            state.key,
            state.manager,
            remote.epoch,
            remote.seq,
            :standby,
            remote.primary,
            remote.standby,
            agent_snapshot
          )

        apply_snapshot(state, snapshot)

      _ ->
        %{state | epoch: remote.epoch, seq: remote.seq, primary: remote.primary, standby: remote.standby}
        |> publish_summary()
    end
  end

  defp maybe_push_primary_state(%{role: :primary} = state, peer, _desired_primary, _desired_standby) do
    winner_primary = Node.self()
    winner_standby = if replica_count(state.manager) > 0, do: peer, else: nil

    if winner_standby do
      case do_sync_standby(%{state | primary: winner_primary, standby: winner_standby}, @default_timeout_ms) do
        {:ok, new_state} -> %{new_state | primary: winner_primary, standby: winner_standby} |> publish_summary()
        _ -> state
      end
    else
      %{state | primary: winner_primary, standby: nil} |> publish_summary()
    end
  end

  defp promote_self(state) do
    state
    |> clear_promotion_timer()
    |> set_local_role(:primary)
    |> Map.put(:epoch, state.epoch + 1)
    |> Map.put(:primary, Node.self())
    |> Map.put(:standby, nil)
    |> publish_summary()
  end

  defp clear_promotion_timer(%{promotion_timer: nil} = state), do: state

  defp clear_promotion_timer(%{promotion_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | promotion_timer: nil}
  end

  defp apply_snapshot(state, %RuntimeSnapshot{} = snapshot) do
    {agent, agent_module} = snapshot_agent_payload!(snapshot, state.agent_module)

    state =
      state
      |> stop_local_agent()
      |> start_snapshot_agent(agent, agent_module, snapshot.cluster_role)

    state
    |> clear_promotion_timer()
    |> Map.put(:agent_module, agent_module)
    |> Map.put(:role, snapshot.cluster_role)
    |> Map.put(:epoch, snapshot.epoch)
    |> Map.put(:seq, snapshot.seq)
    |> Map.put(:primary, snapshot.primary)
    |> Map.put(:standby, snapshot.standby)
    |> publish_summary()
  end

  defp ensure_agent_started(%{agent_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: state, else: ensure_agent_started(%{state | agent_pid: nil})
  end

  defp ensure_agent_started(state) do
    state
    |> Map.put(:agent_pid, nil)
    |> start_fresh_agent(state.role)
  end

  defp set_local_role(%{role: role} = state, role), do: publish_summary(state)

  defp set_local_role(%{agent_pid: pid} = state, role) when is_pid(pid) do
    case capture_agent_snapshot(pid) do
      {:ok, %{agent: agent, agent_module: agent_module}} ->
        state
        |> Map.put(:role, role)
        |> stop_local_agent()
        |> start_snapshot_agent(agent, agent_module, role)
        |> publish_summary()

      {:error, _reason} ->
        %{state | role: role} |> publish_summary()
    end
  end

  defp set_local_role(state, role) do
    %{state | role: role} |> publish_summary()
  end

  defp capture_agent_snapshot(pid) when is_pid(pid) do
    with {:ok, server_state} <- AgentServer.state(pid),
         {:ok, agent} <- Map.fetch(server_state, :agent),
         {:ok, agent_module} <- Map.fetch(server_state, :agent_module),
         true <- is_atom(agent_module) do
      {:ok, %{agent: agent, agent_module: agent_module}}
    else
      false -> {:error, :invalid_agent_module}
      :error -> {:error, :invalid_agent_snapshot}
      {:error, _} = error -> error
    end
  end

  defp start_fresh_agent(state, role) do
    opts =
      [
        agent: state.agent_module,
        agent_module: state.agent_module,
        jido: state.jido,
        register_global: false,
        skip_schedules: role == :standby,
        initial_state: state.initial_state
      ] ++ state.agent_opts

    start_agent_server(state, opts)
  end

  defp start_snapshot_agent(state, agent, agent_module, role) do
    opts =
      [
        agent: agent,
        agent_module: agent_module,
        jido: state.jido,
        register_global: false,
        skip_schedules: role == :standby
      ] ++ state.agent_opts

    state
    |> Map.put(:agent_module, agent_module)
    |> start_agent_server(opts)
  end

  defp start_agent_server(state, opts) do
    child_spec = Supervisor.child_spec({AgentServer, opts}, restart: :temporary)
    supervisor = Jido.agent_supervisor_name(state.jido)

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        Process.monitor(pid)
        %{state | agent_pid: pid} |> publish_summary()

      {:error, {:already_started, pid}} ->
        Process.monitor(pid)
        %{state | agent_pid: pid} |> publish_summary()
    end
  end

  defp snapshot_agent_payload!(%RuntimeSnapshot{} = snapshot, default_agent_module) do
    case snapshot_agent_payload(snapshot, default_agent_module) do
      {:ok, agent, agent_module} ->
        {agent, agent_module}

      {:error, reason} ->
        raise Jido.Cluster.Error.validation_error("Invalid runtime snapshot", %{details: reason})
    end
  end

  defp snapshot_agent_payload(
         %RuntimeSnapshot{agent_snapshot: agent_snapshot, agent_module: snapshot_module},
         default_agent_module
       )
       when is_map(agent_snapshot) do
    with {:ok, agent} <- Map.fetch(agent_snapshot, :agent),
         agent_module when is_atom(agent_module) <-
           snapshot_module || Map.get(agent_snapshot, :agent_module) || Map.get(agent, :agent_module) ||
             default_agent_module do
      {:ok, agent, agent_module}
    else
      :error -> {:error, :missing_agent}
      other -> {:error, {:invalid_agent_module, other}}
    end
  end

  defp stop_local_agent(%{agent_pid: pid} = state) when is_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end

    %{state | agent_pid: nil} |> publish_summary()
  end

  defp stop_local_agent(state), do: state
end
