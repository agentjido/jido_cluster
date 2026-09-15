defmodule JidoCluster.LeaseRenewer do
  @moduledoc false

  use GenServer

  alias Jido.Cluster.LeaseBackend
  alias JidoCluster.LeaseStore

  @type state :: %{
          manager: term(),
          backend: LeaseBackend.t()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    manager = Keyword.fetch!(opts, :manager)

    %{
      id: {__MODULE__, manager},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    manager = Keyword.fetch!(opts, :manager)
    GenServer.start_link(__MODULE__, opts, name: name(manager))
  end

  @spec name(term()) :: atom()
  def name(manager), do: Module.concat(__MODULE__, "#{manager}")

  @impl true
  def init(opts) do
    state = %{
      manager: Keyword.fetch!(opts, :manager),
      backend: Keyword.fetch!(opts, :backend)
    }

    schedule_renewal(state)

    {:ok, state}
  end

  @impl true
  def handle_info(:renew, state) do
    renew_local_keys(state)
    schedule_renewal(state)

    {:noreply, state}
  end

  defp schedule_renewal(%{backend: %LeaseBackend{renew_interval_ms: interval_ms}}) do
    Process.send_after(self(), :renew, interval_ms)
  end

  defp renew_local_keys(state) do
    state.manager
    |> local_keys()
    |> Enum.each(&renew_local_key(state, &1))
  end

  defp local_keys(manager) do
    manager
    |> Jido.Agent.InstanceManager.stats()
    |> Map.get(:keys, [])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp renew_local_key(%{manager: manager, backend: backend}, key) do
    case LeaseStore.acquire_or_renew(manager, key, Node.self(), backend) do
      {:ok, _lease} ->
        :ok

      {:error, reason} ->
        stop_stale_runtime(manager, key, reason)
    end
  end

  defp stop_stale_runtime(manager, key, reason) do
    case Jido.Agent.InstanceManager.stop(manager, key) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    :telemetry.execute(
      [:jido_cluster, :lease_renewer, :stale_stop],
      %{count: 1},
      %{manager: manager, key: key, holder: Node.self(), reason: reason}
    )
  end
end
