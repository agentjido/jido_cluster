defmodule JidoCluster.Internal.Remote do
  @moduledoc false

  @doc false
  @spec rpc(node(), module(), atom(), [term()], timeout()) :: {:ok, term()} | {:error, term()}
  def rpc(node, module, function, args, timeout \\ 5_000) do
    {:ok, :erpc.call(node, module, function, args, timeout)}
  catch
    :exit, reason -> {:error, {:rpc_exit, node, reason}}
    kind, reason -> {:error, {:rpc_error, node, kind, reason}}
  end
end
