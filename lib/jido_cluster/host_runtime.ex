defmodule Jido.Cluster.HostRuntime do
  @moduledoc """
  Host-local identity and control registration for trusted connected BEAM nodes.

  This process attaches to an existing core instance. A Cluster instance starts
  its local host runtime after core. Other hosts start the same child explicitly.
  Disconnect closes the control guard; it does not prove that Agents are dead.
  The host retains scope, capacity, and claims across guard process restarts in
  VM-local memory. This record is tied to the core PID. A restarted guard is
  closed until an owner reconciles the exact retained set. The record does not
  replace the durable control journal and does not survive a VM restart.
  Registration is not an authorization boundary against malicious BEAM peers.

  One guard serves each local core. An application can declare fixed partitions
  before attaching services: `allocations: %{"blue" => 2, "green" => 3}`. Each
  service selects an allocation ID in its configured host record. One scope can
  register one allocation per core/host. Limits do not change during that core
  lifetime. Without this option, the single `"default"` allocation binds its
  capacity at first confirmation. Separate allocations cannot claim the same
  core Ref. Legacy and unmanaged consumers need separate operator-set budgets.

  An owned provider runtime supplies `provider_step: Step.to_record(step)` at
  startup. Probes can require this exact identity. The stamp cannot change for
  the same Core PID, including after a guard restart. Borrowed and static hosts
  can omit it. Prepared code and connected peers remain trusted.
  """
  use GenServer
  alias Jido.Cluster.HostProvider.Step

  @guard_fields [:owner, :owner_monitor, :scope, :control, :claims, :capacity, :retiring_step]

  @doc "Returns the host service name for a core instance."
  @spec name(atom()) :: atom()
  def name(jido), do: Module.concat(jido, ClusterHost)

  @doc "Starts the local host runtime attached to core."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    jido = Keyword.fetch!(opts, :jido)
    GenServer.start_link(__MODULE__, opts, name: name(jido))
  end

  @doc "Attaches an instance to the shared host guard for its core lifetime."
  @spec attach(keyword()) :: :ignore | {:error, term()}
  def attach(opts), do: attach(opts, 1)

  defp attach(opts, retries) do
    child = Supervisor.child_spec({__MODULE__, opts}, restart: :transient)

    result =
      case DynamicSupervisor.start_child(Jido.Cluster.HostSupervisor, child) do
        {:ok, pid} -> attached_core(pid, Keyword.fetch!(opts, :jido))
        {:error, {:already_started, pid}} -> attached_core(pid, Keyword.fetch!(opts, :jido))
        error -> error
      end

    case result do
      {:retired, pid} when retries > 0 ->
        monitor = Process.monitor(pid)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> attach(opts, retries - 1)
        after
          5_000 ->
            Process.demonitor(monitor, [:flush])
            {:error, :host_shutdown_uncertain}
        end

      {:retired, _} ->
        {:error, :host_lifetime_changed}

      other ->
        other
    end
  end

  @doc "Directly probes compatibility using a bounded request."
  @spec probe(GenServer.server(), keyword(), timeout()) :: {:ok, map()} | {:error, term()}
  def probe(host, expected, timeout \\ 5_000), do: GenServer.call(host, {:probe, expected}, timeout)

  @doc "Registers a connected scope owner for the current incarnation."
  @spec register(GenServer.server(), pid(), term(), String.t(), String.t()) :: :ok | {:error, term()}
  def register(host, owner, scope, incarnation, allocation \\ "default"),
    do: GenServer.call(host, {:register, owner, scope, incarnation, allocation})

  @doc "Reopens control only after the retained claim set has been reconciled."
  @spec reconcile(GenServer.server(), pid(), term(), String.t(), [term()], String.t()) :: :ok | {:error, term()}
  def reconcile(host, owner, scope, incarnation, claims, allocation \\ "default"),
    do: GenServer.call(host, {:reconcile, owner, scope, incarnation, claims, allocation})

  @doc "Reports host identity, guard state, and retained claims."
  @spec status(GenServer.server()) :: map()
  def status(host), do: GenServer.call(host, :status)

  @doc "Closes an empty allocation for one provider release step for the rest of this Core lifetime."
  @spec retire(GenServer.server(), pid(), term(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def retire(host, owner, scope, incarnation, step, allocation \\ "default"),
    do: GenServer.call(host, {:retire, owner, scope, incarnation, step, allocation})

  @doc "Confirms scope-reserved claims against the current incarnation and slot budget."
  @spec confirm(GenServer.server(), pid(), term(), String.t(), pos_integer(), [map()]) :: :ok | {:error, term()}
  def confirm(host, owner, scope, incarnation, capacity, claims),
    do: GenServer.call(host, {:confirm, owner, scope, incarnation, capacity, claims})

  @doc "Checks the same confirmed claims before a core activation request."
  @spec verify(GenServer.server(), pid(), term(), String.t(), [term()]) :: :ok | {:error, term()}
  def verify(host, owner, scope, incarnation, ids),
    do: GenServer.call(host, {:verify, owner, scope, incarnation, ids})

  @doc "Releases exact claims only after the placement owner confirms retirement."
  @spec release(GenServer.server(), pid(), term(), String.t(), [term()], term()) :: :ok | {:error, term()}
  def release(host, owner, scope, incarnation, ids, evidence),
    do: GenServer.call(host, {:release, owner, scope, incarnation, ids, evidence})

  @impl true
  def init(opts) do
    jido = Keyword.fetch!(opts, :jido)
    namespace = Jido.namespace(jido)

    core_pid = Process.whereis(jido)

    if is_binary(namespace) and is_pid(core_pid) do
      identity = %{
        id: Keyword.get(opts, :id, Atom.to_string(node())),
        node: node(),
        incarnation: Jido.generate_id(),
        namespace: namespace,
        protocol: 1,
        release: Keyword.get(opts, :release, release()),
        persistence_identity: Keyword.get(opts, :persistence_identity, persistence(jido)),
        provider_step: Keyword.get(opts, :provider_step),
        services: [:core]
      }

      state =
        %{
          identity: identity,
          jido: jido,
          core: Process.monitor(core_pid),
          core_pid: core_pid,
          owner: nil,
          owner_monitor: nil,
          scope: nil,
          control: :unregistered,
          retiring_step: nil,
          claims: [],
          capacity: nil
        }

      with :ok <- validate_provider_step(identity.provider_step),
           {:ok, allocations} <- allocations(opts, state),
           {:ok, allocations} <- restore(jido, core_pid, allocations, identity.provider_step) do
        {:ok, state |> Map.drop(@guard_fields) |> Map.put(:allocations, allocations) |> retain()}
      else
        {:error, reason} -> {:stop, reason}
      end
    else
      {:stop, :jido_not_started}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    allocations =
      Map.new(state.allocations, fn {id, guard} ->
        {id, Map.take(guard, [:control, :scope, :claims, :capacity, :retiring_step])}
      end)

    summary =
      Map.get(allocations, "default", %{
        control: :partitioned,
        scope: nil,
        claims: Enum.flat_map(Map.values(allocations), & &1.claims),
        capacity: Enum.sum(Enum.map(Map.values(allocations), &(&1.capacity || 0)))
      })

    {:reply, state.identity |> Map.merge(summary) |> Map.put(:allocations, allocations), state}
  end

  def handle_call({:probe, expected}, _from, state), do: {:reply, check(state, expected), state}

  def handle_call({:attached_core, pid}, _from, state) do
    cond do
      pid == state.core_pid -> {:reply, :ok, state}
      Process.alive?(state.core_pid) -> {:reply, {:error, :host_core_changed}, state}
      true -> {:stop, :normal, :retired, state}
    end
  end

  def handle_call({:register, owner, scope, incarnation, allocation}, from, state),
    do: with_partition(state, allocation, {:register, owner, scope, incarnation}, from)

  def handle_call({:reconcile, owner, scope, incarnation, claims, allocation}, from, state),
    do: with_partition(state, allocation, {:reconcile, owner, scope, incarnation, claims}, from)

  def handle_call({:retire, owner, scope, incarnation, step, allocation}, from, state),
    do: with_partition(state, allocation, {:retire, owner, scope, incarnation, step}, from)

  def handle_call(request, from, state) when elem(request, 0) in [:confirm, :verify, :release] do
    scope = elem(request, 2)

    case Enum.find(state.allocations, fn {_, guard} -> guard.scope == scope end) do
      {allocation, _} -> with_partition(state, allocation, request, from)
      nil -> {:reply, {:error, :scope_already_owned}, state}
    end
  end

  defp with_partition(state, id, request, from) do
    scope = elem(request, 2)
    conflict = Enum.any?(state.allocations, fn {other, guard} -> other != id and guard.scope == scope end)

    if conflict do
      {:reply, {:error, :scope_allocation_conflict}, state}
    else
      apply_partition(state, id, request, from)
    end
  end

  defp apply_partition(state, id, request, from) do
    case Map.fetch(state.allocations, id) do
      {:ok, partition} ->
        guard = state |> Map.merge(partition) |> Map.put(:allocation, id)
        {:reply, result, next} = handle_guard_call(request, from, guard)
        next = %{state | allocations: Map.put(state.allocations, id, Map.take(next, @guard_fields))}
        {:reply, result, retain(next)}

      :error ->
        {:reply, {:error, :unknown_allocation}, state}
    end
  end

  defp handle_guard_call({:register, owner, scope, incarnation}, _from, state) do
    result =
      cond do
        incarnation != state.identity.incarnation -> {:error, :stale_incarnation}
        state.retiring_step != nil -> {:error, :host_retiring}
        state.control == :reconcile -> {:error, :reconciliation_required}
        state.owner != nil and {state.owner, state.scope} != {owner, scope} -> {:error, :scope_already_owned}
        not is_pid(owner) -> {:error, :invalid_owner}
        true -> :ok
      end

    {:reply, result, if(result == :ok, do: bind(state, owner, scope), else: state)}
  end

  defp handle_guard_call({:reconcile, owner, scope, incarnation, claims}, _from, state) do
    result =
      cond do
        incarnation != state.identity.incarnation -> {:error, :stale_incarnation}
        state.retiring_step != nil -> {:error, :host_retiring}
        ownership_conflict?(state, owner, scope) -> {:error, :scope_already_owned}
        claims != state.claims -> {:error, :claim_mismatch}
        not is_pid(owner) -> {:error, :invalid_owner}
        true -> :ok
      end

    {:reply, result, if(result == :ok, do: bind(state, owner, scope), else: state)}
  end

  defp handle_guard_call({:retire, owner, scope, incarnation, step}, _from, state) do
    result =
      cond do
        incarnation != state.identity.incarnation -> {:error, :stale_incarnation}
        ownership_conflict?(state, owner, scope) -> {:error, :scope_already_owned}
        not valid_release?(owner, step) -> {:error, :invalid_release_step}
        state.claims != [] -> {:error, :claims_retained}
        state.retiring_step not in [nil, step] -> {:error, :release_step_changed}
        true -> :ok
      end

    next = if result == :ok, do: %{bind(state, owner, scope) | control: :retired, retiring_step: step}, else: state
    {:reply, result, next}
  end

  defp handle_guard_call({:confirm, owner, scope, incarnation, capacity, claims}, _from, state) do
    with :ok <- authorized(state, owner, scope, incarnation),
         :ok <- capacity_match(state.capacity, capacity),
         {:ok, combined} <- merge_claims(state, claims, capacity) do
      {:reply, :ok, %{state | claims: combined, capacity: capacity}}
    else
      error -> {:reply, error, state}
    end
  end

  defp handle_guard_call({:verify, owner, scope, incarnation, ids}, _from, state) do
    result =
      with :ok <- authorized(state, owner, scope, incarnation),
           true <- Enum.all?(ids, fn id -> Enum.any?(state.claims, &(&1.id == id)) end),
           do: :ok

    result = if result == false, do: {:error, :unconfirmed_claim}, else: result
    {:reply, result, state}
  end

  defp handle_guard_call({:release, owner, scope, incarnation, ids, :confirmed}, _from, state) do
    with :ok <- authorized(state, owner, scope, incarnation),
         :ok <- verify_absence(state, ids) do
      {:reply, :ok, %{state | claims: Enum.reject(state.claims, &(&1.id in ids))}}
    else
      error -> {:reply, error, state}
    end
  end

  defp handle_guard_call({:release, _, _, _, _, _}, _from, state),
    do: {:reply, {:error, :unconfirmed_cleanup}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{core: ref} = state) do
    :persistent_term.erase(retention_key(state.jido))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    allocations =
      Map.new(state.allocations, fn {id, guard} ->
        next =
          if guard.owner_monitor == ref, do: %{guard | control: :reconcile, owner: nil, owner_monitor: nil}, else: guard

        {id, next}
      end)

    {:noreply, %{state | allocations: allocations}}
  end

  defp ownership_conflict?(state, owner, scope),
    do: (state.scope != nil and state.scope != scope) or (state.owner != nil and state.owner != owner)

  defp valid_release?(owner, step), do: is_pid(owner) and is_binary(step) and byte_size(step) in 1..256

  defp bind(state, owner, scope) do
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    %{state | owner: owner, owner_monitor: Process.monitor(owner), scope: scope, control: :ready}
  end

  # Write before acknowledgement. Process death after this write can only retain
  # too many claims, never admit a second activation into an occupied slot.
  # One named guard writes each record. One record per core name bounds keys.
  defp retain(state) do
    key = retention_key(state.jido)

    allocations =
      Map.new(state.allocations, fn {id, guard} ->
        {id, Map.take(guard, [:scope, :claims, :capacity, :retiring_step])}
      end)

    snapshot = %{core_pid: state.core_pid, allocations: allocations, provider_step: state.identity.provider_step}
    if :persistent_term.get(key, nil) != snapshot, do: :persistent_term.put(key, snapshot)
    state
  end

  defp retention_key(jido), do: {__MODULE__, :claims, jido}

  defp attached_core(pid, jido) do
    case GenServer.call(pid, {:attached_core, Process.whereis(jido)}) do
      :ok -> :ignore
      :retired -> {:retired, pid}
      error -> error
    end
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:normal, :noproc] -> {:retired, pid}
    :exit, reason -> {:error, {:host_attach_failed, reason}}
  end

  defp authorized(state, owner, scope, incarnation) do
    cond do
      incarnation != state.identity.incarnation -> {:error, :stale_incarnation}
      state.control != :ready -> {:error, :reconciliation_required}
      {state.owner, state.scope} != {owner, scope} -> {:error, :scope_already_owned}
      true -> :ok
    end
  end

  defp capacity_match(nil, capacity) when is_integer(capacity) and capacity > 0, do: :ok
  defp capacity_match(capacity, capacity) when is_integer(capacity) and capacity > 0, do: :ok
  defp capacity_match(_, _), do: {:error, :capacity_conflict}

  defp verify_absence(state, ids) do
    state.claims
    |> Enum.filter(&(&1.id in ids))
    |> Enum.reduce_while(:ok, fn claim, :ok ->
      case Jido.resolve_agent(state.jido, claim.ref) do
        {:error, :not_found} -> {:cont, :ok}
        {:ok, _pid} -> {:halt, {:error, :activation_still_present}}
        error -> {:halt, {:error, {:activation_unknown, error}}}
      end
    end)
  catch
    :exit, reason -> {:error, {:activation_unknown, reason}}
  end

  defp merge_claims(state, claims, capacity) do
    existing = Map.new(state.claims, &{&1.id, &1})

    valid =
      Enum.all?(claims, fn claim ->
        claim.scope == state.scope and claim.host_incarnation == state.identity.incarnation and
          Map.get(claim, :allocation, "default") == state.allocation and
          Map.get(existing, claim.id, claim) == claim
      end)

    combined = Map.merge(existing, Map.new(claims, &{&1.id, &1})) |> Map.values() |> Enum.sort_by(& &1.id)

    cond do
      not valid -> {:error, :claim_conflict}
      ref_conflict?(state, claims) -> {:error, :ref_already_claimed}
      length(combined) > capacity -> {:error, :no_capacity}
      true -> {:ok, combined}
    end
  end

  defp ref_conflict?(state, claims) do
    refs = MapSet.new(claims, & &1.ref)

    Enum.any?(state.allocations, fn {id, guard} ->
      id != state.allocation and Enum.any?(guard.claims, &MapSet.member?(refs, &1.ref))
    end)
  end

  defp allocations(opts, state) do
    budgets = Keyword.get(opts, :allocations, %{"default" => nil})
    implicit = not Keyword.has_key?(opts, :allocations)

    valid = is_map(budgets) and map_size(budgets) > 0 and Enum.all?(budgets, &valid_allocation?(&1, implicit))

    if valid do
      base = Map.take(state, @guard_fields)
      {:ok, Map.new(budgets, fn {id, capacity} -> {id, %{base | capacity: capacity}} end)}
    else
      {:error, :invalid_allocations}
    end
  end

  defp valid_allocation?({"default", nil}, true), do: true

  defp valid_allocation?({id, capacity}, _),
    do: is_binary(id) and byte_size(id) in 1..128 and is_integer(capacity) and capacity > 0

  defp validate_provider_step(nil), do: :ok

  defp validate_provider_step(record) do
    case Step.from_record(record) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_provider_step}
    end
  end

  defp restore(jido, core_pid, allocations, provider_step) do
    case :persistent_term.get(retention_key(jido), nil) do
      %{core_pid: ^core_pid, allocations: previous} = saved ->
        if Map.get(saved, :provider_step) == provider_step,
          do: restore_allocations(allocations, previous),
          else: {:error, :provider_step_changed}

      %{core_pid: ^core_pid} ->
        {:error, :unsupported_host_record}

      _ ->
        {:ok, allocations}
    end
  end

  defp restore_allocations(allocations, previous) do
    valid =
      Enum.sort(Map.keys(allocations)) == Enum.sort(Map.keys(previous)) and
        Enum.all?(allocations, fn {id, guard} -> guard.capacity == nil or guard.capacity == previous[id].capacity end)

    if valid do
      {:ok,
       Map.new(allocations, fn {id, guard} ->
         {id, guard |> Map.merge(previous[id]) |> Map.put(:control, :reconcile)}
       end)}
    else
      {:error, :allocation_conflict}
    end
  end

  defp check(state, expected) do
    fields = [:namespace, :protocol, :release, :persistence_identity, :provider_step]

    mismatch =
      Enum.find(
        fields,
        &(Keyword.has_key?(expected, &1) and Keyword.get(expected, &1) != Map.fetch!(state.identity, &1))
      )

    missing =
      Enum.find(
        Keyword.get(expected, :modules, []),
        &(not Code.ensure_loaded?(&1) or not function_exported?(&1, :new, 0))
      )

    services = Keyword.get(expected, :services, []) -- state.identity.services

    cond do
      mismatch -> {:error, {:incompatible, mismatch}}
      missing -> {:error, {:missing_module, missing}}
      services != [] -> {:error, {:missing_services, services}}
      true -> {:ok, state.identity}
    end
  end

  defp release,
    do: %{
      cluster: Application.spec(:jido_cluster, :vsn),
      core: Application.spec(:jido, :vsn),
      otp: System.otp_release()
    }

  defp persistence(jido) do
    case Jido.instance_persistence(jido) do
      nil -> :none
      {adapter, _opts} -> {:adapter, adapter}
    end
  end
end
