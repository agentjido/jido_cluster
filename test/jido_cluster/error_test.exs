defmodule JidoCluster.ErrorTest do
  use ExUnit.Case, async: true

  alias JidoCluster.Error

  test "validation_error/2 returns InvalidInputError" do
    error = Error.validation_error("invalid key", %{field: :key, value: nil})

    assert %Error.InvalidInputError{} = error
    assert error.message == "invalid key"
    assert error.field == :key
    assert error.value == nil
  end

  test "config_error/2 returns ConfigError" do
    error = Error.config_error("missing repo", %{key: :repo})

    assert %Error.ConfigError{} = error
    assert error.message == "missing repo"
    assert error.key == :repo
  end

  test "execution_error/2 returns ExecutionFailureError" do
    error = Error.execution_error("rpc failed", %{reason: :nodedown})

    assert %Error.ExecutionFailureError{} = error
    assert error.message == "rpc failed"
    assert error.details == %{reason: :nodedown}
  end
end
