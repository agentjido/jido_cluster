defmodule JidoCluster.Test.Eventually do
  @moduledoc false

  @spec eventually((-> term()), keyword()) :: term()
  def eventually(fun, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout, 2_000)
    interval_ms = Keyword.get(opts, :interval, 20)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_eventually(fun, deadline, interval_ms, nil)
  end

  defp do_eventually(fun, deadline, interval_ms, last) do
    if System.monotonic_time(:millisecond) > deadline do
      raise ExUnit.AssertionError,
        message: "Condition not met before timeout. Last value: #{inspect(last)}"
    end

    case fun.() do
      value when value not in [nil, false] ->
        value

      value ->
        Process.sleep(interval_ms)
        do_eventually(fun, deadline, interval_ms, value)
    end
  end
end
