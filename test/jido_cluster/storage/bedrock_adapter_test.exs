defmodule JidoCluster.Storage.BedrockAdapterTest do
  use ExUnit.Case, async: false

  alias JidoCluster.Storage.Bedrock

  defmodule FakeBedrockRepo do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def transact(fun), do: transact(fun, [])

    def transact(fun, _opts) do
      try do
        fun.()
      catch
        {:rollback, reason} -> {:error, reason}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})

    def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

    def put(key, value) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
      :ok
    end

    def clear(key) do
      Agent.update(__MODULE__, &Map.delete(&1, key))
      :ok
    end

    def get_range({start_key, end_key}) do
      Agent.get(__MODULE__, fn state ->
        state
        |> Enum.filter(fn {key, _value} -> key >= start_key and key < end_key end)
        |> Enum.sort_by(&elem(&1, 0))
      end)
    end

    def clear_range({start_key, end_key}) do
      Agent.update(__MODULE__, fn state ->
        state
        |> Enum.reject(fn {key, _value} -> key >= start_key and key < end_key end)
        |> Map.new()
      end)

      :ok
    end
  end

  setup do
    start_supervised!(FakeBedrockRepo)
    FakeBedrockRepo.reset()
    :ok
  end

  defp opts do
    [repo: FakeBedrockRepo, prefix: "test/#{System.unique_integer([:positive])}/"]
  end

  test "checkpoint operations" do
    opts = opts()
    key = {:agent, "1"}
    data = %{state: %{a: 1}}

    assert :not_found = Bedrock.get_checkpoint(key, opts)
    assert :ok = Bedrock.put_checkpoint(key, data, opts)
    assert {:ok, ^data} = Bedrock.get_checkpoint(key, opts)
    assert :ok = Bedrock.delete_checkpoint(key, opts)
    assert :not_found = Bedrock.get_checkpoint(key, opts)
  end

  test "expected_rev conflict" do
    opts = opts()
    thread_id = "thread-#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             Bedrock.append_thread(thread_id, [%{kind: :note, payload: %{n: 1}}], Keyword.put(opts, :expected_rev, 0))

    assert first.rev == 1

    assert {:error, :conflict} =
             Bedrock.append_thread(thread_id, [%{kind: :note, payload: %{n: 2}}], Keyword.put(opts, :expected_rev, 0))
  end
end
