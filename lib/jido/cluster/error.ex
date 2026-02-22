defmodule Jido.Cluster.Error do
  @moduledoc """
  Error helper facade for `jido_cluster`.

  Preferred public namespace. Delegates to `JidoCluster.Error`.
  """

  @doc "Builds an invalid-input exception with optional details."
  @spec validation_error(String.t(), map()) :: Exception.t()
  def validation_error(message, details \\ %{}) when is_binary(message) and is_map(details) do
    JidoCluster.Error.validation_error(message, details)
  end

  @doc "Builds a configuration exception with optional details."
  @spec config_error(String.t(), map()) :: Exception.t()
  def config_error(message, details \\ %{}) when is_binary(message) and is_map(details) do
    JidoCluster.Error.config_error(message, details)
  end

  @doc "Builds an execution exception with optional details."
  @spec execution_error(String.t(), map()) :: Exception.t()
  def execution_error(message, details \\ %{}) when is_binary(message) and is_map(details) do
    JidoCluster.Error.execution_error(message, details)
  end
end
