defmodule Jido.Cluster.Rebalancer do
  @moduledoc """
  Conservative periodic rebalancer for distributed keyed agents.

  Preferred public namespace. Delegates to `JidoCluster.Rebalancer`.
  """

  @doc "Child specification for a manager-scoped rebalancer worker."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: JidoCluster.Rebalancer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: JidoCluster.Rebalancer

  @doc false
  @spec name(term()) :: atom()
  defdelegate name(manager), to: JidoCluster.Rebalancer

  @doc "Forces an immediate rebalance tick (useful for tests)."
  @spec trigger(term()) :: :ok
  defdelegate trigger(manager), to: JidoCluster.Rebalancer

  @doc "Forces an immediate rebalance tick and waits for completion (useful for tests)."
  @spec trigger_sync(term(), timeout()) :: :ok
  defdelegate trigger_sync(manager, timeout \\ 5_000), to: JidoCluster.Rebalancer
end
