defmodule JidoCluster.Error do
  @moduledoc """
  Centralized error handling for `jido_cluster` using Splode.

  Error classes are used for coarse classification while concrete exception
  structs are used for raising and matching package-specific errors.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  defmodule Invalid do
    @moduledoc "Invalid input error class for Splode."

    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Execution error class for Splode."

    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."

    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Splode."

    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      defexception [:message, :details]
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Error for invalid input parameters."

    defexception [:message, :field, :value, :details]
  end

  defmodule ConfigError do
    @moduledoc "Error for invalid or missing package configuration."

    defexception [:message, :key, :value, :details]
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for runtime execution failures."

    defexception [:message, :details]
  end

  @doc "Builds an invalid-input exception with optional details."
  @spec validation_error(String.t(), map()) :: Exception.t()
  def validation_error(message, details \\ %{}) when is_binary(message) and is_map(details) do
    InvalidInputError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end

  @doc "Builds a configuration exception with optional details."
  @spec config_error(String.t(), map()) :: Exception.t()
  def config_error(message, details \\ %{}) when is_binary(message) and is_map(details) do
    ConfigError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end

  @doc "Builds an execution exception with optional details."
  @spec execution_error(String.t(), map()) :: Exception.t()
  def execution_error(message, details \\ %{}) when is_binary(message) and is_map(details) do
    ExecutionFailureError.exception(message: message, details: details)
  end
end
