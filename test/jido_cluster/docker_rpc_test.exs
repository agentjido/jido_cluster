defmodule JidoCluster.DockerRPCTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias JidoCluster.Test.DockerHost.RPC

  defmodule Barrier do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, test}

    def handle_call(:wait, {caller, _}, test) do
      send(test, {:entered, caller})
      {:noreply, test}
    end
  end

  test "the trusted transport preserves public result terms and matches the request ID" do
    {:ok, id, encoded} = RPC.request(:erlang, :self, [], 1_000)
    output = capture_io(fn -> assert :ok = RPC.run(encoded) end)
    assert {:ok, worker} = RPC.response(id, output)
    assert is_pid(worker)
    refute Process.alive?(worker)
    assert {:error, :invalid_rpc_response} = RPC.response(String.duplicate("0", 32), output)
    assert {:error, :invalid_rpc_response} = RPC.response(id, output <> output)
    {:ok, id, encoded} = RPC.request(Map, :get, [%{a: {:ok, make_ref()}}, :a], 1_000)
    assert {:ok, ^id, {:ok, {:ok, reference}}} = RPC.invoke(encoded)
    assert is_reference(reference)
  end

  test "timeout kills the actual waiting process and confirms its termination" do
    barrier = start_supervised!({Barrier, self()})
    {:ok, id, encoded} = RPC.request(GenServer, :call, [barrier, :wait, :infinity], 1_000)
    caller = Task.async(fn -> RPC.invoke(encoded) end)
    assert_receive {:entered, worker}, 1_000
    monitor = Process.monitor(worker)
    assert {:ok, ^id, {:error, :rpc_timeout}} = Task.await(caller, 3_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    refute Process.alive?(worker)
    assert Process.alive?(barrier)
    stop_supervised!(Barrier)
    refute Process.alive?(barrier)
  end

  test "errors and large results return bounded values without exception data" do
    for {module, function, args} <- [
          {Map, :fetch!, [%{}, "secret-value"]},
          {:erlang, :exit, [:private_reason]}
        ] do
      {:ok, id, encoded} = RPC.request(module, function, args, 1_000)
      assert {:ok, ^id, result} = RPC.invoke(encoded)
      assert result == {:error, :rpc_failed}
    end

    {:ok, id, encoded} = RPC.request(:binary, :copy, ["x", 131_073], 1_000)
    assert {:ok, ^id, {:error, :rpc_reply_limit}} = RPC.invoke(encoded)
  end

  test "invalid, compressed, oversized and trailing ETF input cannot execute" do
    {:ok, _, encoded} = RPC.request(:erlang, :node, [], 1_000)
    bytes = Base.decode64!(encoded)
    compressed = :erlang.term_to_binary(String.duplicate("x", 40_000), [:compressed])

    for invalid <- ["invalid", Base.encode64(compressed), Base.encode64(bytes <> <<0>>), String.duplicate("a", 50_000)] do
      assert {:error, :invalid_rpc_request} = RPC.invoke(invalid)
    end

    assert {:error, :invalid_rpc_request} = RPC.request(:erlang, :node, [], :infinity)
    assert {:error, :invalid_rpc_request} = RPC.request(:erlang, :node, [], 40_001)
    assert {:error, :invalid_rpc_request} = RPC.request(:erlang, :node, [String.duplicate("x", 33_000)], 1_000)
  end
end
