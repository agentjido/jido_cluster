defmodule JidoCluster.Internal.InstanceManagerConfig do
  @moduledoc false

  @doc false
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(manager) do
    case :persistent_term.get({Jido.Agent.InstanceManager, manager}, :undefined) do
      :undefined -> :error
      config when is_map(config) -> {:ok, config}
      _other -> :error
    end
  rescue
    _ -> :error
  end

  @doc false
  @spec fetch_storage(term()) :: {module(), keyword()} | nil | :error
  def fetch_storage(manager) do
    with {:ok, config} <- fetch(manager) do
      Map.get(config, :storage)
    end
  end
end
