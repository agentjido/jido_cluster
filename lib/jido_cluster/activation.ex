defmodule Jido.Cluster.Activation do
  @moduledoc """
  Retains exact activation cleanup evidence within one control runtime.

  The journal stores an activation identity before work starts. A Deployment owner
  claims that identity before it can create a core Controller, and settles it only
  after confirmed cleanup. Owner death is not settlement. A restarted evidence
  process has a new runtime identity, so missing state cannot authorize activation.

  One record per scope and topology is retained. A new attempt replaces a settled
  record; it cannot replace an uncertain attempt. This is process-restart evidence,
  not a durable lease, a VM-loss proof, or automatic cross-node takeover.

  Each attempt also retains at most 256 host/channel resource records. A mirror
  claims its record before creating children. Only that exact process can confirm
  their cleanup. Deployment cleanup closes new resource admission first and cannot
  settle until every claimed resource has supplied its receipt. These VM-local
  process records are not part of the portable deployment journal.

  Resource revisions start at zero. Only the deployment owner can close a
  revision or prepare its immediate successor. Preparation requires confirmed
  cleanup of the previous revision. The record is replaced in place, so repeated
  generations do not grow the resource count. A stale process or revision cannot
  authorize control or settle a replacement. An unused revision can be closed
  atomically before delayed creation. Missing processes never prove cleanup.
  """
  use GenServer
  import Kernel, except: [inspect: 1]
  alias Jido.Cluster.Deployment.Owner

  @doc "Starts the local activation evidence process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Creates a portable attempt identity without claiming or starting resources."
  @spec new({String.t(), String.t()}, String.t()) :: map()
  def new({namespace, scope}, topology),
    do: GenServer.call(__MODULE__, {:new, namespace, scope, topology})

  @doc "Claims an attempt before its owner starts a Controller."
  @spec claim(map() | nil, pid()) :: :ok | {:error, term()}
  def claim(nil, _owner), do: :ok
  def claim(activation, owner), do: GenServer.call(__MODULE__, {:claim, activation, owner})

  @doc "Checks that the exact live owner can still create resources for this attempt."
  @spec authorize(map(), pid()) :: :ok | {:error, term()}
  def authorize(activation, owner), do: GenServer.call(__MODULE__, {:authorize, activation, owner})

  @doc "Closes resource admission before the exact owner starts cleanup."
  @spec close(map() | nil, pid()) :: :ok | {:error, term()}
  def close(nil, _owner), do: :ok
  def close(activation, owner), do: GenServer.call(__MODULE__, {:close, activation, owner})

  @doc "Claims one host/channel resource before it can create local children."
  @spec claim_resource(map(), pid(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def claim_resource(activation, owner, channel, revision \\ 0),
    do: GenServer.call({__MODULE__, node(owner)}, {:claim_resource, activation, owner, channel, revision})

  @doc "Authorizes control from the exact active mirror process and resource revision."
  @spec authorize_resource(map(), pid(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def authorize_resource(activation, owner, channel, revision),
    do: GenServer.call({__MODULE__, node(owner)}, {:authorize_resource, activation, owner, channel, revision})

  @doc "Reads the current resource revision, phase, and exact process owner."
  @spec resource_state(map(), pid(), node(), String.t()) :: {:ok, map()} | {:error, term()}
  def resource_state(activation, owner, host, channel),
    do: GenServer.call({__MODULE__, node(owner)}, {:resource_state, activation, owner, host, channel})

  @doc "Closes one resource generation from its deployment owner before local cleanup."
  @spec close_resource(map(), pid(), node(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def close_resource(activation, owner, host, channel, revision),
    do:
      GenServer.call({__MODULE__, node(owner)}, {:resource_change, :close, activation, owner, host, channel, revision})

  @doc "Prepares exactly the next revision after confirmed prior generation cleanup."
  @spec prepare_resource(map(), pid(), node(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def prepare_resource(activation, owner, host, channel, revision),
    do:
      GenServer.call(
        {__MODULE__, node(owner)},
        {:resource_change, :prepare, activation, owner, host, channel, revision}
      )

  @doc "Reads retained resource evidence without inferring cleanup from absence."
  @spec resource(map(), pid(), node(), String.t()) :: {:ok, :unstarted | :settled | {:active, pid()}} | {:error, term()}
  def resource(activation, owner, host, channel),
    do: GenServer.call({__MODULE__, node(owner)}, {:resource, activation, owner, host, channel})

  @doc "Lists all resource keys claimed by the exact deployment owner."
  @spec resources(map(), pid()) :: {:ok, [{node(), String.t()}]} | {:error, term()}
  def resources(activation, owner),
    do: GenServer.call({__MODULE__, node(owner)}, {:resources, activation, owner})

  @doc "Records local child cleanup from the exact process that claimed the resource."
  @spec settle_resource(map(), pid(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def settle_resource(activation, owner, channel, revision \\ 0),
    do: GenServer.call({__MODULE__, node(owner)}, {:settle_resource, activation, owner, channel, revision})

  @doc "Records confirmed cleanup for the exact owner and attempt."
  @spec settle(map() | nil, pid()) :: :ok | {:error, term()}
  def settle(nil, _owner), do: :ok
  def settle(activation, owner), do: GenServer.call(__MODULE__, {:settle, activation, owner})

  @doc "Reads evidence without inferring cleanup from process absence."
  @spec inspect(map()) :: {:ok, :settled | {:active, pid()}} | {:error, term()}
  def inspect(activation), do: GenServer.call(__MODULE__, {:inspect, activation})

  @doc "Closes an unclaimed attempt so its delayed owner cannot start it."
  @spec unstarted(map()) :: :ok | {:error, term()}
  def unstarted(activation), do: GenServer.call(__MODULE__, {:unstarted, activation})

  @doc "Requests exact-owner cleanup or returns its retained confirmation."
  @spec cleanup(map()) :: :ok | {:error, term()}
  def cleanup(activation) do
    case inspect(activation) do
      {:ok, :settled} -> :ok
      {:ok, {:active, owner}} -> Owner.stop(owner)
      error -> error
    end
  catch
    :exit, _ -> {:error, :cleanup_unconfirmed}
  end

  @impl true
  def init(nil), do: {:ok, %{runtime: Jido.generate_id(), records: %{}}}

  @impl true
  def handle_call({:new, namespace, scope, topology}, _from, state) do
    serial =
      case Map.get(state.records, {namespace, scope, topology}) do
        nil -> 1
        record -> record.activation.serial + 1
      end

    activation = %{
      id: Jido.generate_id(),
      runtime: state.runtime,
      node: Atom.to_string(node()),
      namespace: namespace,
      scope: scope,
      topology_id: topology,
      serial: serial
    }

    {:reply, activation, state}
  end

  def handle_call({:claim, activation, owner}, _from, state) do
    with :ok <- same_runtime(activation, state),
         :ok <- valid_owner(owner),
         :ok <- claimable(Map.get(state.records, key(activation)), activation, owner) do
      resources =
        case Map.get(state.records, key(activation)) do
          %{activation: ^activation, resources: resources} -> resources
          _ -> %{}
        end

      record = %{activation: activation, owner: owner, status: :active, resources: resources}
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:settle, activation, owner}, {caller, _}, state) do
    with :ok <- same_runtime(activation, state),
         {:ok, record} <- exact(state, activation),
         true <- record.owner == owner and caller == owner,
         :ok <- resources_settled(record) do
      record = %{record | status: :settled}
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      false -> {:reply, {:error, :owner_mismatch}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:authorize, activation, owner}, _from, state) do
    result =
      with :ok <- same_runtime(activation, state),
           {:ok, record} <- exact(state, activation),
           :ok <- resource_owner(record, owner),
           do: valid_owner(owner)

    {:reply, result, state}
  end

  def handle_call({:close, activation, owner}, {caller, _}, state) do
    with :ok <- same_runtime(activation, state),
         {:ok, record} <- exact(state, activation),
         true <- record.owner == owner and caller == owner do
      record = if record.status == :active, do: %{record | status: :closing}, else: record
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      false -> {:reply, {:error, :owner_mismatch}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:claim_resource, activation, owner, channel, revision}, {caller, _}, state) do
    with :ok <- same_runtime(activation, state),
         {:ok, record} <- exact(state, activation),
         :ok <- resource_owner(record, owner),
         :ok <- valid_owner(owner),
         true <- valid_channel?(channel),
         :ok <- valid_revision(revision),
         :ok <- resource_claimable(record.resources, {node(caller), channel}, caller, revision) do
      resource = %{owner: caller, status: :active, revision: revision}
      record = put_in(record, [:resources, {node(caller), channel}], resource)
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      false -> {:reply, {:error, :invalid_channel}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:authorize_resource, activation, owner, channel, revision}, {caller, _}, state) do
    result =
      with :ok <- same_runtime(activation, state),
           {:ok, record} <- exact(state, activation),
           :ok <- resource_owner(record, owner),
           :ok <- valid_owner(owner),
           resource = Map.get(record.resources, {node(caller), channel}, empty_resource()),
           :ok <- same_revision(resource, revision),
           true <- resource.status == :active and resource.owner == caller do
        :ok
      else
        false -> {:error, :resource_closed}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:resource_state, activation, owner, host, channel}, _, state) do
    result =
      with :ok <- same_runtime(activation, state),
           {:ok, record} <- exact(state, activation),
           true <- record.owner == owner do
        resource = Map.get(record.resources, {host, channel}, empty_resource())
        {:ok, %{revision: resource.revision, phase: resource.status, owner: resource.owner}}
      else
        false -> {:error, :owner_mismatch}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:resource_change, change, activation, owner, host, channel, revision}, {caller, _}, state) do
    with :ok <- same_runtime(activation, state),
         {:ok, record} <- exact(state, activation),
         :ok <- resource_owner(record, owner),
         true <- caller == owner,
         :ok <- valid_owner(owner),
         true <- valid_channel?(channel) and is_atom(host) and host not in [nil, true, false],
         :ok <- valid_revision(revision),
         :ok <- resource_capacity(record.resources, {host, channel}),
         resource = Map.get(record.resources, {host, channel}, empty_resource()),
         {:ok, next} <- change_resource(change, resource, revision) do
      record = put_in(record, [:resources, {host, channel}], next)
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      false -> {:reply, {:error, :invalid_resource_request}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resource, activation, owner, host, channel}, _, state) do
    result =
      with :ok <- same_runtime(activation, state),
           {:ok, record} <- exact(state, activation),
           true <- record.owner == owner do
        case Map.get(record.resources, {host, channel}) do
          nil -> {:ok, :unstarted}
          resource -> {:ok, resource_observation(resource)}
        end
      else
        false -> {:error, :owner_mismatch}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:resources, activation, owner}, _, state) do
    result =
      with :ok <- same_runtime(activation, state),
           {:ok, record} <- exact(state, activation),
           true <- record.owner == owner do
        {:ok, record.resources |> Map.keys() |> Enum.sort()}
      else
        false -> {:error, :owner_mismatch}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:settle_resource, activation, owner, channel, revision}, {caller, _}, state) do
    with :ok <- same_runtime(activation, state),
         {:ok, record} <- exact(state, activation),
         true <- record.owner == owner,
         %{owner: ^caller} = resource <- Map.get(record.resources, {node(caller), channel}),
         :ok <- same_revision(resource, revision) do
      record = put_in(record, [:resources, {node(caller), channel}], %{resource | status: :settled})
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :owner_mismatch}, state}
    end
  end

  def handle_call({:inspect, activation}, _from, state) do
    result =
      with :ok <- same_runtime(activation, state), {:ok, record} <- exact(state, activation), do: observation(record)

    {:reply, result, state}
  end

  def handle_call({:unstarted, activation}, _from, state) do
    with :ok <- same_runtime(activation, state),
         :ok <- closable(Map.get(state.records, key(activation)), activation) do
      record = %{activation: activation, owner: nil, status: :settled, resources: %{}}
      {:reply, :ok, %{state | records: Map.put(state.records, key(activation), record)}}
    else
      error -> {:reply, error, state}
    end
  end

  defp same_runtime(
         %{id: id, runtime: runtime, node: host, namespace: ns, scope: scope, topology_id: topology, serial: serial} =
           activation,
         state
       )
       when map_size(activation) == 7 do
    valid = Enum.all?([id, runtime, host, ns, scope, topology], &valid_string?/1) and is_integer(serial) and serial > 0

    cond do
      not valid -> {:error, :invalid_activation}
      byte_size(id) != 36 or byte_size(runtime) != 36 -> {:error, :invalid_activation}
      runtime != state.runtime or host != Atom.to_string(node()) -> {:error, :runtime_changed}
      true -> :ok
    end
  end

  defp same_runtime(_, _), do: {:error, :invalid_activation}
  defp valid_string?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp valid_owner(owner) when is_pid(owner) do
    if node(owner) == node() and Process.alive?(owner), do: :ok, else: {:error, :invalid_owner}
  end

  defp valid_owner(_), do: {:error, :invalid_owner}

  defp key(a), do: {a.namespace, a.scope, a.topology_id}

  defp exact(state, activation) do
    case Map.get(state.records, key(activation)) do
      %{activation: ^activation} = record -> {:ok, record}
      nil -> {:error, :activation_missing}
      _ -> {:error, :activation_changed}
    end
  end

  defp claimable(nil, _activation, _owner), do: :ok

  defp claimable(%{activation: activation, status: :settled}, activation, _owner),
    do: {:error, :activation_closed}

  defp claimable(%{activation: activation, owner: owner, status: :active}, activation, owner), do: :ok

  defp claimable(%{activation: prior}, activation, _) when activation.serial <= prior.serial,
    do: {:error, :activation_changed}

  defp claimable(%{status: :settled}, _, _), do: :ok
  defp claimable(_, _, _), do: {:error, :cleanup_unconfirmed}

  defp closable(%{activation: activation, status: :settled}, activation), do: :ok
  defp closable(record, activation), do: claimable(record, activation, nil)

  defp resource_owner(%{status: status}, _) when status in [:closing, :settled],
    do: {:error, :activation_closed}

  defp resource_owner(%{owner: owner, status: :active}, owner), do: :ok
  defp resource_owner(_, _), do: {:error, :owner_mismatch}

  defp resource_claimable(resources, key, caller, revision) do
    resource = Map.get(resources, key, empty_resource())

    with :ok <- resource_capacity(resources, key),
         :ok <- same_revision(resource, revision) do
      case resource do
        %{owner: ^caller, status: :active} -> :ok
        %{status: :unstarted} -> :ok
        _ -> {:error, :resource_cleanup_unconfirmed}
      end
    end
  end

  defp empty_resource, do: %{owner: nil, status: :unstarted, revision: 0}
  defp valid_channel?(channel), do: is_binary(channel) and byte_size(channel) in 1..128 and String.valid?(channel)
  defp valid_revision(revision) when is_integer(revision) and revision in 0..9_007_199_254_740_991, do: :ok
  defp valid_revision(_), do: {:error, :invalid_resource_revision}

  defp same_revision(%{revision: revision}, revision), do: :ok
  defp same_revision(_, _), do: {:error, :resource_revision_changed}

  defp resource_capacity(resources, key) do
    if Map.has_key?(resources, key) or map_size(resources) < 256, do: :ok, else: {:error, :resource_capacity}
  end

  defp change_resource(:close, %{revision: revision} = resource, revision) do
    status =
      case resource.status do
        :unstarted -> :settled
        :active -> :closing
        other -> other
      end

    {:ok, %{resource | status: status}}
  end

  defp change_resource(:prepare, %{revision: revision} = resource, revision), do: {:ok, resource}

  defp change_resource(:prepare, %{revision: prior, status: :settled}, revision) when revision == prior + 1,
    do: {:ok, %{owner: nil, status: :unstarted, revision: revision}}

  defp change_resource(:prepare, %{revision: prior}, revision) when revision == prior + 1,
    do: {:error, :resource_cleanup_unconfirmed}

  defp change_resource(_, _, _), do: {:error, :resource_revision_changed}

  defp resources_settled(record) do
    if Enum.all?(record.resources, fn {_, resource} -> resource.status in [:settled, :unstarted] end),
      do: :ok,
      else: {:error, :resource_cleanup_unconfirmed}
  end

  defp resource_observation(%{status: :settled}), do: :settled
  defp resource_observation(%{status: :unstarted}), do: :unstarted
  defp resource_observation(%{owner: owner}), do: {:active, owner}

  defp observation(%{status: :settled}), do: {:ok, :settled}

  defp observation(%{owner: owner}) do
    if Process.alive?(owner), do: {:ok, {:active, owner}}, else: {:error, :cleanup_unconfirmed}
  end
end
