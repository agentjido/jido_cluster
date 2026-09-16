defmodule Jido.Cluster.Journal.Snapshot.Reader do
  @moduledoc false
  alias Jido.Agent.Ref
  alias Jido.Cluster.{Admission, Journal}
  alias Jido.Cluster.Federation.{Intent, Transition}
  alias Jido.Cluster.Journal.{Definition, HostSessions}
  alias Jido.Topology.Plan
  @phases [:accepted, :completed, :failed, :uncertain]

  @doc "Checks the complete record before it can become recovery intent."
  @spec decode(term(), map(), term()) :: {:ok, map()} | {:error, term()}
  def decode(document, config, registry) do
    require_value(is_map(document) and not is_struct(document), :invalid_object)
    document = document |> Map.put_new("host_sessions", []) |> Map.put_new("host_providers", [])

    object(
      document,
      ~w(version namespace scope generation epoch hosts excluded claims deployments operations requests host_sessions host_providers)
    )

    require_value(document["version"] === 1, :unsupported_snapshot)
    require_value(document["namespace"] == config.namespace and document["scope"] == config.scope, :scope_mismatch)
    scope = {config.namespace, config.scope}
    generation = uuid(document["generation"])
    epoch = document["epoch"]
    require_value(is_integer(epoch) and epoch >= 0, :invalid_epoch)
    {:ok, inventory} = Admission.new(scope, config.hosts)
    hosts = Map.new(inventory.hosts, fn {node, host} -> {Atom.to_string(node), host} end)
    inventory(document["hosts"], hosts)
    require_value(document["host_providers"] == HostSessions.providers(config), :provider_inventory_changed)

    sessions =
      case HostSessions.decode(document["host_sessions"], config) do
        {:ok, sessions} -> sessions
        {:error, reason} -> invalid(reason)
      end

    deployments = unique(document["deployments"], Journal.limits().deployments, &deployment(&1, registry, hosts, scope))
    context = %{hosts: hosts, scope: scope, deployments: deployments}
    claims = unique(document["claims"], Journal.limits().claims, &claim(&1, context))
    excluded = collection(document["excluded"], Journal.limits().hosts) |> Enum.map(&host(&1, hosts))
    require_value(length(excluded) == length(Enum.uniq(excluded)), :duplicate_exclusion)
    operations = unique(document["operations"], Journal.limits().request_bindings, &operation(&1, context))
    require_value(HostSessions.operations(sessions, operations, config) == :ok, :invalid_host_operation)
    unresolved = Enum.count(operations, fn {_, op} -> op.phase not in [:completed, :failed] end)
    require_value(unresolved <= Journal.limits().unresolved_operations, :operation_limit)

    requests =
      unique(
        document["requests"],
        Journal.limits().request_bindings,
        &request(&1, scope, generation, epoch, operations)
      )

    validate_bindings(context, operations, claims)

    ledger = %{
      inventory
      | claims: claims,
        excluded: MapSet.new(excluded),
        requests: reservations(claims),
        provider_pending: MapSet.new(Map.keys(Map.get(config, :host_providers, %{})))
    }

    {:ok,
     %{
       generation: generation,
       epoch: epoch,
       deployments: deployments,
       host_sessions: sessions,
       operations: operations,
       requests: requests,
       ledger: ledger
     }}
  catch
    {:invalid_snapshot, reason} -> {:error, {:invalid_snapshot, reason}}
  end

  defp inventory(records, hosts) do
    restored =
      unique(records, Journal.limits().hosts, fn record ->
        object(record, ~w(node capacity labels available allocation))
        node = host(record["node"], hosts)
        expected = Map.fetch!(hosts, record["node"])

        require_value(
          record["capacity"] === expected.capacity and record["available"] === expected.available and
            record["labels"] == Enum.sort(expected.labels) and record["allocation"] == expected.allocation,
          :inventory_changed
        )

        {node, expected}
      end)

    require_value(map_size(restored) == map_size(hosts), :inventory_changed)
  end

  defp deployment(record, registry, hosts, scope) do
    require_value(is_map(record), :invalid_binding_intent)
    legacy = not Map.has_key?(record, "federation")
    record = Map.put_new(record, "federation", nil)
    record = Map.put_new(record, "federation_transition", nil)

    object(
      record,
      ~w(definition activation recovery recovery_hosts selected initial_selected desired phase reason operation prior_phase federation federation_transition)
    )

    instance =
      case Definition.decode(record["definition"], registry) do
        {:ok, instance} -> instance
        {:error, reason} -> invalid({:definition, reason})
      end

    selected = placement(record["selected"], instance, hosts)
    initial_selected = placement(record["initial_selected"], instance, hosts)
    require_value(map_size(selected) == map_size(instance.plan.agents), :incomplete_placement)
    require_value(map_size(initial_selected) == map_size(instance.plan.agents), :incomplete_initial_placement)

    deployment = %{
      instance: instance,
      activation: activation(record["activation"], scope, instance.id),
      recovery: enum(record["recovery"], [:idle, :pending, :uncertain]),
      recovery_hosts: recovery_hosts(record["recovery_hosts"], hosts),
      selected: selected,
      initial_selected: initial_selected,
      runner: nil,
      desired: enum(record["desired"], [:running, :stopped]),
      phase: enum(record["phase"], @phases),
      reason: reason(record["reason"]),
      operation: string(record["operation"])
    }

    deployment =
      if record["prior_phase"] == nil,
        do: deployment,
        else: Map.put(deployment, :prior_phase, enum(record["prior_phase"], @phases))

    intent =
      if legacy do
        case Intent.new(instance, selected, deployment.activation) do
          {:ok, value} -> value
          _ -> invalid(:invalid_binding_intent)
        end
      else
        record["federation"]
      end

    require_value(Intent.validate(intent, instance, selected, deployment.activation) == :ok, :invalid_binding_intent)
    deployment = Map.put(deployment, :federation, intent)
    transition = binding_transition(record["federation_transition"], deployment, hosts)
    deployment = Map.put(deployment, :federation_transition, transition)

    {instance.id, deployment}
  end

  defp binding_transition(nil, _, _), do: nil

  defp binding_transition(record, deployment, hosts) when is_map(record) do
    previous = placement(record["from"], deployment.instance, hosts)
    require_value(map_size(previous) == map_size(deployment.selected), :incomplete_binding_source)
    allowed = Map.keys(hosts) ++ [deployment.activation.node]
    require_value(Transition.validate(record, deployment, previous, allowed) == :ok, :invalid_binding_transition)
    record
  end

  defp binding_transition(_, _, _), do: invalid(:invalid_binding_transition)

  defp recovery_hosts(record, hosts) when is_map(record) and map_size(record) <= 32,
    do: Map.new(record, fn {node, incarnation} -> {host(node, hosts), string(incarnation)} end)

  defp recovery_hosts(_, _), do: invalid(:invalid_recovery_hosts)

  defp activation(record, {namespace, scope}, topology) do
    object(record, ~w(id runtime node namespace scope topology_id serial))
    require_value(is_integer(record["serial"]) and record["serial"] > 0, :invalid_activation_serial)

    require_value(
      record["namespace"] == namespace and record["scope"] == scope and record["topology_id"] == topology,
      :activation_scope_mismatch
    )

    %{
      id: uuid(record["id"]),
      runtime: uuid(record["runtime"]),
      node: string(record["node"]),
      namespace: namespace,
      scope: scope,
      topology_id: topology,
      serial: record["serial"]
    }
  end

  defp claim(record, context) do
    object(record, ~w(topology ref host allocation incarnation operation state))
    topology = string(record["topology"])
    deployment = fetch(context.deployments, topology, :unknown_deployment)
    ref = ref(record["ref"], deployment.instance, context.scope)
    node = host(record["host"], context.hosts)
    allocation = fetch(context.hosts, record["host"], :unknown_host).allocation
    require_value(record["allocation"] == allocation, :allocation_mismatch)
    id = {topology, ref, node}

    {id,
     %{
       id: id,
       scope: context.scope,
       topology_id: topology,
       ref: ref,
       host: node,
       allocation: allocation,
       host_incarnation: optional_string(record["incarnation"]),
       operation_id: string(record["operation"]),
       state: enum(record["state"], [:reserved, :active, :uncertain])
     }}
  end

  defp operation(record, context) do
    object(record, ~w(id attempt action topology phase reason host steps))
    id = string(record["id"])
    {namespace, scope} = context.scope
    action = enum(record["action"], [:deploy, :stop, :drain, :enable_host, :acquire_host, :release_host])

    op = %{
      id: id,
      attempt_id: string(record["attempt"]),
      action: action,
      topology_id: optional_string(record["topology"]),
      phase: enum(record["phase"], @phases),
      reason: reason(record["reason"]),
      namespace: namespace,
      scope: scope
    }

    {id, operation_target(op, record, context)}
  end

  defp operation_target(%{action: action} = op, record, context) when action in [:deploy, :stop] do
    fetch(context.deployments, op.topology_id, :unknown_deployment)
    require_value(record["host"] == nil and record["steps"] == [], :invalid_operation_target)
    op
  end

  defp operation_target(op, record, context) do
    require_value(op.topology_id == nil, :invalid_operation_target)
    op = Map.put(op, :host, host(record["host"], context.hosts))

    if op.action == :drain do
      Map.put(op, :steps, unique(record["steps"], Journal.limits().deployments, &step(&1, context)))
    else
      require_value(
        record["steps"] == [] and (op.action != :enable_host or op.phase == :completed),
        :invalid_operation_target
      )

      op
    end
  end

  defp step(record, context) do
    object(record, ~w(topology operation phase selected arrivals retired))
    id = string(record["topology"])
    instance = fetch(context.deployments, id, :unknown_deployment).instance
    selected = placement(record["selected"], instance, context.hosts)
    arrivals = placement(record["arrivals"], instance, context.hosts)
    require_value(map_size(selected) == map_size(instance.plan.agents), :incomplete_placement)
    require_value(Enum.all?(arrivals, fn {key, host} -> selected[key] == host end), :invalid_arrival)

    retired =
      unique(record["retired"], Journal.limits().claims, fn
        [id, node] -> {ref(id, instance, context.scope), host(node, context.hosts)}
        _ -> invalid(:invalid_retirement)
      end)

    {id,
     %{
       operation_id: string(record["operation"]),
       phase: enum(record["phase"], @phases),
       selected: selected,
       arrivals: arrivals,
       retired: retired
     }}
  end

  defp request(record, scope, generation, epoch, operations) do
    object(record, ~w(nonce fingerprint operation))
    token = %{scope: scope, generation: generation, epoch: epoch, nonce: uuid(record["nonce"])}
    fingerprint = string(record["fingerprint"])

    digest =
      case Base.decode16(fingerprint, case: :lower) do
        {:ok, digest} when byte_size(digest) == 32 -> digest
        _ -> invalid(:invalid_fingerprint)
      end

    id = string(record["operation"])
    fetch(operations, id, :unknown_operation)
    {token, {digest, id}}
  end

  defp placement(value, instance, hosts) when is_map(value) and not is_struct(value) do
    require_value(map_size(value) <= Journal.limits().claims, :claim_limit)

    Map.new(value, fn {key, node} ->
      string(key)
      require_value(Map.has_key?(instance.plan.agents, Plan.resolve(instance.plan, key, :agent)), :unknown_agent)
      {key, host(node, hosts)}
    end)
  end

  defp placement(_, _, _), do: invalid(:invalid_placement)

  defp ref(id, instance, {namespace, _}) do
    string(id)
    require_value(Enum.any?(instance.plan.agents, fn {_, spec} -> spec.id == id end), :unknown_agent)

    case Ref.new(namespace: namespace, id: id) do
      {:ok, ref} -> ref
      _ -> invalid(:invalid_ref)
    end
  end

  defp validate_bindings(context, operations, claims) do
    Enum.each(context.deployments, fn {id, d} ->
      if d.phase in [:accepted, :uncertain], do: fetch(operations, d.operation, :unknown_operation)
      validate_deployment_claims(id, d, claims, context.scope)
    end)

    Enum.each(Enum.group_by(Map.values(claims), & &1.operation_id), fn {_, group} ->
      require_value(length(Enum.uniq_by(group, & &1.topology_id)) == 1, :claim_operation_conflict)
      require_value(length(Enum.uniq_by(group, & &1.ref)) == length(group), :claim_operation_conflict)
    end)

    Enum.each(Enum.frequencies_by(Map.values(claims), & &1.host), fn {node, count} ->
      require_value(count <= context.hosts[Atom.to_string(node)].capacity, :capacity_exceeded)
    end)
  end

  defp validate_deployment_claims(id, %{desired: :stopped, phase: :completed}, claims, _) do
    require_value(not Enum.any?(claims, fn {_, claim} -> claim.topology_id == id end), :stopped_claims)
  end

  defp validate_deployment_claims(id, %{desired: :running, phase: phase} = d, claims, scope)
       when phase != :failed do
    Enum.each(d.selected, fn {key, node} ->
      spec = d.instance.plan.agents[Plan.resolve(d.instance.plan, key, :agent)]
      ref = ref(spec.id, d.instance, scope)
      claim = fetch(claims, {id, ref, node}, :missing_placement_claim)
      require_value(phase != :completed or d.recovery != :idle or claim.state == :active, :inactive_placement_claim)
    end)
  end

  defp validate_deployment_claims(_, _, _, _), do: :ok

  defp reservations(claims) do
    claims
    |> Map.values()
    |> Enum.group_by(& &1.operation_id)
    |> Map.new(fn {id, [first | _] = group} ->
      {id, {first.topology_id, Map.new(group, &{&1.ref, &1.host})}}
    end)
  end

  defp host(name, hosts), do: fetch(hosts, name, :unknown_host).node
  defp fetch(map, key, reason), do: Map.get(map, key) || invalid(reason)

  defp object(value, keys) when is_map(value) and not is_struct(value),
    do: require_value(Enum.sort(Map.keys(value)) == Enum.sort(keys), :invalid_fields)

  defp object(_, _), do: invalid(:invalid_object)

  defp string(value) when is_binary(value) and byte_size(value) > 0 do
    require_value(String.valid?(value), :invalid_string)
    value
  end

  defp string(_), do: invalid(:invalid_string)
  defp optional_string(nil), do: nil
  defp optional_string(value), do: string(value)

  defp uuid(value) do
    string(value)
    require_value(byte_size(value) == 36, :invalid_identity)
    value
  end

  defp enum(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value)) || invalid(:invalid_enum)
  defp reason(nil), do: nil

  defp reason(value) do
    string(value)
    require_value(byte_size(value) <= 512, :reason_limit)
    {:recorded_reason, value}
  end

  defp collection(value, limit) when is_list(value) and length(value) <= limit, do: value
  defp collection(_, _), do: invalid(:collection_limit)

  defp unique(value, limit, fun) do
    pairs = value |> collection(limit) |> Enum.map(fun)
    map = Map.new(pairs)
    require_value(map_size(map) == length(pairs), :duplicate_identity)
    map
  end

  defp require_value(true, _), do: :ok
  defp require_value(false, reason), do: invalid(reason)
  defp invalid(reason), do: throw({:invalid_snapshot, reason})
end
