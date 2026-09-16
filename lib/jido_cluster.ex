defmodule Jido.Cluster do
  @moduledoc """
  Named deployment services and connected BEAM placement for Jido V3 Agents.

  `use Jido.Cluster, otp_app: :my_app` defines a named OTP instance. It owns
  core unless an explicit `:jido` instance is supplied. The deployment facade
  shares configured capacity, confirms host claims, and drains root singleton
  topologies through core. Operation storage uses an explicitly selected memory
  mode or a core persistence adapter with an application-owned trusted registry.
  Durable writes and explicit recovery of running, interrupted, or stopped intent
  are supported. Restart blocks mutations until reconciliation confirms cleanup
  and current ownership. Control-runtime loss remains uncertain.
  Static declared channels support required local bindings and bounded best-effort
  publication from the control node. Managed movement journals source retirement
  and target attachment; explicit bridge repair retains the accepted Agent.
  Optional configured host providers use the same scope journal. Provider hosts
  stay closed until an explicit acquisition and direct runtime check complete.
  Release retains hosts with claims and records cleanup before external deletion.

  `Jido.Cluster.Entity` maps bounded domain identities to root singleton core
  Topologies. Entity demand uses this instance's same admission, claims, journal,
  drain, and recovery path. Its versioned Ref is stable across a cooperative
  move.

  This foundation does not provide disconnected island leases or live replicas.

  Request retention is bounded to 64 accepted bindings per epoch, including
  unresolved requests. A full epoch expires only when all its operations have
  completed or failed. `request_id/1` then advances the epoch; older tokens return
  `:expired_request`, and older operation IDs return `:not_found`. Live claims and
  deployment intent remain. An uncertain request prevents expiry and can cause
  `:retention_saturated`. `status/1` reports the limits and current retention use.

  ## Operation telemetry

  `[:jido, :cluster, :operation, :start | :stop | :exception]` follows the
  `:telemetry.span/3` contract. Metadata includes namespace, scope, topology ID,
  operation ID, attempt ID, action, and exact claim IDs. The stop event includes
  the observed phase and reason. These events run in the operation task; a stop
  event is an observation, not proof that the authority recorded completion.

  `[:jido, :cluster, :placement, :ready]` reports target readiness during a drain,
  before source claims are released. Metadata includes the parent operation ID,
  step operation ID, selected hosts, and retiring Ref demand. Its measurement is
  `system_time` in native time units. It does not establish full drain completion.
  """

  alias Jido.Cluster.Federation.{Bridge, Runtime}
  alias Jido.Cluster.Instance.Service

  @doc "Defines a named Cluster instance with application configuration."
  defmacro __using__(opts) do
    quote do
      alias Jido.Cluster.Instance
      alias Jido.Cluster.Instance.Config, as: ClusterConfig
      @cluster_defaults unquote(opts)

      @doc "Validates module, application, and start options, in that order."
      @spec config(keyword()) :: {:ok, Jido.Cluster.Instance.Config.t()} | {:error, term()}
      def config(overrides \\ []) do
        ClusterConfig.new(__MODULE__, @cluster_defaults, overrides)
      end

      @doc "Starts this Cluster instance."
      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(overrides \\ []) do
        with {:ok, config} <- config(overrides), do: Instance.start_link(config)
      end

      @doc "Returns this instance's supervisor child specification."
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(overrides) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [overrides]}, type: :supervisor, shutdown: :infinity}
      end
    end
  end

  @doc "Returns the validated configuration of a running instance."
  @spec config(atom()) :: {:ok, Jido.Cluster.Instance.Config.t()}
  def config(instance), do: Service.call(instance, :config)

  @doc "Reports current instance health and persistence limits."
  @spec status(atom()) :: map()
  def status(instance), do: Service.call(instance, :status)

  @doc "Plans supported root singleton placement without starting Agents."
  @spec plan(atom(), Jido.Topology.Instance.t()) :: {:ok, map()} | {:error, term()}
  def plan(instance, topology), do: Service.call(instance, {:plan, topology})

  @doc "Reports reserved, active, and uncertain capacity claims for this scope."
  @spec claims(atom()) :: [map()]
  def claims(instance), do: Service.call(instance, :claims)

  @doc "Starts bounded journal and activation reconciliation; observe deployment readiness for completion."
  @spec reconcile(atom()) :: :ok | {:error, term()}
  def reconcile(instance), do: Service.call(instance, :reconcile)

  @doc "Excludes a host and requests a fully reserved drain across its deployments."
  @spec drain(atom(), node(), keyword()) :: {:ok, map()} | {:error, term()}
  def drain(instance, host, opts), do: Service.call(instance, {:drain, host, Keyword.get(opts, :request_id)})

  @doc "Removes drain exclusion only when the host has no unresolved claims or active drain."
  @spec enable_host(atom(), node(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_host(instance, host, opts),
    do: Service.call(instance, {:enable_host, host, Keyword.get(opts, :request_id)})

  @doc "Records a provider acquisition step before requesting a prepared host."
  @spec acquire_host(atom(), node(), keyword()) :: {:ok, map()} | {:error, term()}
  def acquire_host(instance, host, opts),
    do: Service.call(instance, {:host_request, :acquire_host, host, Keyword.get(opts, :request_id)})

  @doc "Closes host admission and requests release after confirmed Agent and binding cleanup."
  @spec release_host(atom(), node(), keyword()) :: {:ok, map()} | {:error, term()}
  def release_host(instance, host, opts),
    do: Service.call(instance, {:host_request, :release_host, host, Keyword.get(opts, :request_id)})

  @doc "Returns recorded provider intent and the current admission gate without provider options."
  @spec host_status(atom(), node()) :: {:ok, map()} | {:error, term()}
  def host_status(instance, host), do: Service.call(instance, {:host_status, host})

  @doc "Creates a request token, or rejects a saturated epoch that has unresolved work."
  @spec request_id(atom()) :: map() | {:error, atom() | tuple()}
  def request_id(instance), do: Service.call(instance, :request_id)

  @doc "Accepts one idempotent deployment request. Completion is separate from acceptance."
  @spec deploy(atom(), Jido.Topology.Instance.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def deploy(instance, topology, opts),
    do: Service.call(instance, {:submit, :deploy, topology, Keyword.get(opts, :request_id)})

  @doc "Records stopped intent and requests confirmed deployment cleanup."
  @spec stop(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stop(instance, id, opts),
    do: Service.call(instance, {:submit, :stop, id, Keyword.get(opts, :request_id)})

  @doc "Reads one accepted operation without changing its state."
  @spec operation(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def operation(instance, id), do: Service.call(instance, {:operation, id})

  @doc "Waits for an operation. A timeout does not cancel or replay work."
  @spec await(atom(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def await(instance, id, timeout \\ 5_000) when is_integer(timeout) and timeout >= 0,
    do: Service.call(instance, {:await, id, timeout}, timeout + 1_000)

  @doc "Reports desired state and independent readiness observations for a deployment."
  @spec status(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(instance, id) do
    with {:ok, context} <- Service.call(instance, {:federation_context, id}), do: Runtime.observe(context)
  end

  @doc "Reports current channel bindings, transport health, and bounded capacity metrics."
  @spec federation_status(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def federation_status(instance, id) do
    with {:ok, context} <- Service.call(instance, {:federation_context, id}), do: Runtime.status(context)
  end

  @doc "Admits one local Signal publication before its payload enters a federation mailbox."
  @spec publish(atom(), String.t(), atom() | String.t(), Jido.Signal.t(), timeout()) :: {:ok, map()} | {:error, term()}
  def publish(instance, id, channel, signal, timeout \\ 5000) do
    with {:ok, context} <- Service.call(instance, {:federation_context, id}),
         {:ok, endpoint} <- Runtime.publisher(context, channel),
         do: Bridge.publish(endpoint, signal, timeout)
  end

  @doc "Builds the exact core Ref for a managed root declaration."
  @spec ref(atom(), String.t(), atom() | String.t()) :: {:ok, Jido.Agent.Ref.t()} | {:error, term()}
  def ref(instance, id, key), do: Service.call(instance, {:ref, id, key})

  @doc "Resolves accepted placement. A missing location is pending, not permission to activate."
  @spec lookup(atom(), Jido.Agent.Ref.t()) :: {:ok, map()} | {:error, term()}
  def lookup(instance, ref), do: Service.call(instance, {:lookup, ref})

  @doc "Calls the current accepted Agent once. Cluster never replays the Signal."
  @spec call(atom(), Jido.Agent.Ref.t(), Jido.Signal.t(), timeout()) :: term()
  def call(instance, ref, signal, timeout \\ 5_000) do
    with {:ok, %{pid: pid}} <- lookup(instance, ref), do: Jido.AgentServer.call(pid, signal, timeout)
  end

  @doc "Returns the visible BEAM nodes, including this node."
  @spec connected_nodes() :: [node()]
  def connected_nodes, do: [node() | Node.list()] |> Enum.uniq() |> Enum.sort()
end
