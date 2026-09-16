defmodule Jido.Cluster.Federation.Runtime do
  @moduledoc """
  Builds declared static channels after core placement and observes their runtime.

  The deployment owner runs setup after core readiness. Mirrors claim exact
  activation resources before creating children. Required local attachment receipts
  precede initial completion. The instance service records accepted host
  incarnations and attachment intent before mirror creation, then records required
  attachment completion. Unknown journal writes stop dependent setup effects.
  Transport health remains a separate observation.
  Publication obtains a local bridge handle without sending its Signal through
  the deployment service. Status reads do not write the journal.
  """

  alias Jido.Agent.Ref
  alias Jido.Cluster.Activation
  alias Jido.Cluster.Federation.{Bridge, Declarations, Limits, Mirror, Movement}
  alias Jido.Cluster.Federation.Transport.Receiver
  alias Jido.Cluster.Instance.{Hosts, Service}
  alias Jido.Topology.{Controller, Instance, Plan}

  @doc "Derives each channel's participants and local bindings without runtime effects."
  @spec plan(Instance.t(), String.t(), map(), node(), Limits.t()) :: {:ok, [map()]} | {:error, term()}
  def plan(instance, namespace, selected, control, limits) do
    with {:ok, channels} <- Declarations.resolve(instance, namespace) do
      locations =
        Map.new(instance.definition.agents, fn agent ->
          spec = Map.fetch!(instance.plan.agents, Plan.resolve(instance.plan, agent.key, :agent))
          {Ref.new!(namespace: namespace, id: spec.id), %{host: Map.get(selected, agent.key), key: agent.key}}
        end)

      plan_channels(channels, locations, control, limits)
    end
  end

  @doc "Confirms declared local bindings under the exact owner before deployment completion."
  @spec setup(map(), pid(), map()) :: :ok | {:error, term()}
  def setup(state, controller, selected) do
    # Legacy Core instances can have no namespace. A topology without channels
    # needs no federation identities, resources, or readiness checks.
    case Declarations.read(state.instance.definition) do
      {:ok, %{"channels" => []}} -> :ok
      {:ok, _} -> setup_declared(state, controller, selected)
      error -> error
    end
  catch
    _, _ -> {:error, {:federation, :setup_uncertain}}
  end

  @doc "Retires recorded source channels before Core movement for a managed deployment."
  @spec before_move(map(), map(), map()) :: :ok | {:error, term()}
  def before_move(state, current, desired) do
    case Declarations.read(state.instance.definition) do
      {:ok, %{"channels" => []}} -> :ok
      {:ok, _} -> Movement.before_move(state, current, desired)
      error -> error
    end
  end

  defp setup_declared(state, controller, selected) do
    with {:ok, channels} <- plan(state.instance, Jido.namespace(state.jido), selected, node(), state.federation),
         :ok <- Hosts.verify(state.guard),
         {:ok, intent} <-
           Service.call(
             state.guard.owner,
             {:federation_attaching, state.instance.id, state.guard.activation, selected, state.guard.binding_revision}
           ),
         :ok <- setup_channels(Map.put(state, :federation_intent, intent), controller, channels),
         do: Service.call(state.guard.owner, {:federation_ready, state.instance.id, state.guard.activation, intent})
  end

  @doc "Returns a caller-local admission handle after initial deployment completion."
  @spec publisher(map(), atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def publisher(context, key) do
    d = context.deployment
    key = if is_atom(key), do: Atom.to_string(key), else: key

    with :ok <- publication_allowed(context),
         {:ok, channels} <- planned(context),
         channel when not is_nil(channel) <- Enum.find(channels, &(elem(&1.scope, 2) == key)),
         {:ok, {:active, owner}} <- Activation.inspect(d.activation),
         :ok <- Activation.authorize(d.activation, owner),
         {:ok, mirror} <- Mirror.lookup(context.config.jido, d.activation, elem(channel.scope, 2)) do
      Mirror.publisher(mirror)
    else
      nil -> {:error, :channel_not_found}
      error -> error
    end
  catch
    :exit, _ -> {:error, :publisher_unavailable}
  end

  @doc "Reads bounded current federation observations without changing operation history."
  @spec status(map()) :: {:ok, map()} | {:error, term()}
  def status(context) do
    with {:ok, channels} <- planned(context) do
      deadline = System.monotonic_time(:millisecond) + context.config.timeout
      observations = Enum.map(channels, &channel_status(&1, context, deadline))
      stopped = context.deployment.desired == :stopped and context.deployment.phase == :completed

      {:ok,
       %{
         namespace: context.config.namespace,
         topology_id: context.deployment.instance.id,
         channels: observations,
         binding_readiness: aggregate_bindings(observations, stopped),
         health: aggregate_health(observations, stopped)
       }}
    end
  end

  @doc "Adds independent current readiness observations to an existing deployment result."
  @spec observe(map()) :: {:ok, map()} | {:error, term()}
  def observe(context) do
    with {:ok, federation} <- status(context) do
      observation =
        Map.merge(context.observation, %{
          binding_readiness: federation.binding_readiness,
          federation_health: federation.health
        })

      observation =
        if federation.channels == [],
          do: observation,
          else: Map.put(observation, :agent_readiness, agent_readiness(context))

      {:ok, observation}
    end
  end

  @doc "Reads one host mirror and its bounded metrics through public component APIs."
  @spec host_status(atom(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def host_status(jido, activation, channel) do
    with {:ok, mirror} <- Mirror.lookup(jido, activation, channel) do
      status = Mirror.status(mirror, 500)
      components = status.components

      summary =
        Map.take(status, [:control, :bindings, :binding_readiness, :federation_health, :connections, :configured])

      {:ok,
       Map.merge(summary, %{
         exports: component_status(Bridge, components.bridge),
         imports: component_status(Receiver, components.receiver)
       })}
    end
  end

  defp channel_plan(channel, locations, control, limits) do
    bindings = Enum.map(channel.bindings, &Map.merge(&1, Map.fetch!(locations, &1.ref)))
    interested = bindings |> Enum.map(& &1.host) |> Enum.uniq() |> Enum.sort()
    hosts = Enum.uniq([control | interested]) |> Enum.sort()

    cond do
      Enum.any?(hosts, &(not is_atom(&1) or is_nil(&1))) -> {:error, :invalid_federation_placement}
      length(hosts) > limits.max_hosts -> {:error, :federation_host_limit}
      true -> {:ok, Map.merge(channel, %{bindings: bindings, hosts: hosts, interested: interested})}
    end
  end

  defp start_channel(state, controller, channel) do
    with {:ok, mirrors} <- start_mirrors(state, channel),
         :ok <- attach_bindings(state, controller, channel, mirrors) do
      # Connectivity does not revoke confirmed local binding readiness. A pending
      # configuration still prevents publication through that local publisher.
      Enum.each(mirrors, &connect_mirror(&1, mirrors, channel, state.timeout))

      :ok
    end
  end

  defp connect_mirror({host, mirror}, mirrors, channel, timeout) do
    interested = channel.interested -- [host]

    destinations =
      Enum.flat_map(interested, fn destination ->
        case rpc(destination, __MODULE__, :receiver, [mirrors[destination]], timeout) do
          {:ok, endpoint} -> [%{host: destination, receiver: endpoint}]
          _ -> []
        end
      end)

    if length(destinations) == length(interested),
      do: rpc(host, Mirror, :connect, [mirror, destinations], timeout)
  end

  defp plan_channels(channels, locations, control, limits) do
    Enum.reduce_while(channels, {:ok, []}, fn channel, {:ok, planned} ->
      case channel_plan(channel, locations, control, limits) do
        {:ok, channel} -> {:cont, {:ok, planned ++ [channel]}}
        error -> {:halt, error}
      end
    end)
  end

  defp setup_channels(state, controller, channels) do
    Enum.reduce_while(channels, :ok, fn channel, :ok ->
      case start_channel(state, controller, channel) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:federation, reason}}}
      end
    end)
  end

  @doc "Returns a mirror's receiver descriptor for connected setup."
  @spec receiver(pid()) :: {:ok, map()}
  def receiver(mirror) do
    %{components: %{receiver: receiver}} = Mirror.status(mirror)
    {:ok, Receiver.endpoint(receiver)}
  end

  defp start_mirrors(state, channel) do
    Enum.reduce_while(channel.hosts, {:ok, %{}}, fn host, {:ok, mirrors} ->
      bindings = channel.bindings |> Enum.filter(&(&1.host == host)) |> Enum.map(&Map.take(&1, [:ref, :required]))

      opts = [
        jido: state.jido,
        activation: state.guard.activation,
        owner: state.owner,
        channel: elem(channel.scope, 2),
        types: channel.types,
        limits: state.federation,
        allowed_nodes: channel.hosts,
        bindings: bindings,
        revision: mirror_revision(state.federation_intent, host, elem(channel.scope, 2))
      ]

      case rpc(host, Mirror, :ensure, [opts], state.timeout) do
        {:ok, mirror} -> {:cont, {:ok, Map.put(mirrors, host, mirror)}}
        {:error, reason} -> {:halt, {:error, {:mirror, host, reason}}}
      end
    end)
  end

  defp mirror_revision(intent, host, channel) do
    Enum.find(intent["mirrors"], &(&1["host"] == Atom.to_string(host) and &1["channel"] == channel))["revision"]
  end

  defp attach_bindings(state, controller, channel, mirrors) do
    Enum.reduce_while(channel.bindings, :ok, fn binding, :ok ->
      target = Controller.whereis_agent(controller, binding.key)

      result =
        if is_pid(target) and node(target) == binding.host,
          do: rpc(binding.host, Mirror, :attach, [mirrors[binding.host], binding.ref, target], state.timeout),
          else: {:error, :location_pending}

      if result == :ok or not binding.required,
        do: {:cont, :ok},
        else: {:halt, {:error, {:required_binding, binding.ref, result}}}
    end)
  end

  defp planned(context),
    do:
      plan(
        context.deployment.instance,
        context.config.namespace,
        context.deployment.selected,
        context.control_node,
        context.config.federation
      )

  defp publication_allowed(context) do
    d = context.deployment

    cond do
      context.store_status != :ready -> {:error, context.store_status}
      d.desired != :running -> {:error, :stopped}
      d.phase != :completed or Map.get(d, :recovery) in [:pending, :uncertain] -> {:error, :not_ready}
      Map.get(d, :binding_busy, false) or Map.get(d, :federation_transition) != nil -> {:error, :not_ready}
      d.activation.node != Atom.to_string(node()) -> {:error, :publisher_not_local}
      true -> :ok
    end
  end

  defp channel_status(channel, context, deadline) do
    hosts =
      Enum.map(channel.hosts, fn host ->
        remaining = deadline - System.monotonic_time(:millisecond)

        result =
          if remaining > 0 and not stopped?(context),
            do:
              rpc(
                host,
                __MODULE__,
                :host_status,
                [context.config.jido, context.deployment.activation, elem(channel.scope, 2)],
                min(remaining, 1000)
              ),
            else: {:error, if(stopped?(context), do: :stopped, else: :observation_timeout)}

        case result do
          {:ok, status} ->
            Map.put(status, :host, host)

          {:error, reason} ->
            %{host: host, binding_readiness: :uncertain, federation_health: :uncertain, reason: reason}
        end
      end)

    %{scope: channel.scope, key: elem(channel.scope, 2), interested_hosts: channel.interested, hosts: hosts}
  end

  defp stopped?(context), do: context.deployment.desired == :stopped and context.deployment.phase == :completed
  defp aggregate_bindings([], _), do: :ready
  defp aggregate_bindings(_, true), do: :stopped

  defp aggregate_bindings(channels, false) do
    values = for channel <- channels, host <- channel.hosts, do: host.binding_readiness

    cond do
      :uncertain in values -> :uncertain
      :degraded in values -> :degraded
      :pending in values -> :pending
      true -> :ready
    end
  end

  defp aggregate_health([], _), do: :disabled
  defp aggregate_health(_, true), do: :stopped

  defp aggregate_health(channels, false) do
    values = for channel <- channels, host <- channel.hosts, do: host.federation_health

    cond do
      :uncertain in values -> :uncertain
      :degraded in values -> :degraded
      :pending in values -> :pending
      true -> :healthy
    end
  end

  defp agent_readiness(context) do
    if context.store_status == :ready and context.deployment.desired == :running and
         Map.get(context.deployment, :recovery) not in [:pending, :uncertain] do
      case Controller.whereis(context.config.jido, context.deployment.instance.id) do
        nil -> :pending
        controller -> Controller.status(controller).status
      end
    else
      context.observation.agent_readiness
    end
  catch
    :exit, _ -> :uncertain
  end

  defp component_status(module, pid) do
    # These processes use the public :status request; a held Bus append must not
    # make a metrics read wait without a bound.
    module.status(pid, 100)
  catch
    :exit, _ -> :unavailable
  end

  defp rpc(host, module, function, args, timeout) do
    if host in [node() | Node.list()],
      do: :erpc.call(host, module, function, args, timeout),
      else: {:error, :host_unreachable}
  catch
    _, _ -> {:error, :runtime_unavailable}
  end
end
