defmodule JidoCluster.Storage.PostgresAdapterTest do
  use ExUnit.Case, async: false

  alias JidoCluster.Storage.Postgres

  defmodule FakePostgresRepo do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{checkpoints: %{}, meta: %{}, entries: %{}} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{checkpoints: %{}, meta: %{}, entries: %{}} end)
    end

    def transaction(fun) do
      try do
        {:ok, fun.()}
      catch
        {:rollback, reason} -> {:error, reason}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})

    def query(sql, params), do: handle_query(String.downcase(sql), params)

    defp handle_query(sql, [key]) when is_binary(key) do
      cond do
        String.contains?(sql, "select data from") ->
          rows =
            Agent.get(__MODULE__, fn %{checkpoints: checkpoints} ->
              case Map.get(checkpoints, key) do
                nil -> []
                value -> [[value]]
              end
            end)

          {:ok, %{rows: rows}}

        String.contains?(sql, "delete from jido_cluster_checkpoints") ->
          Agent.update(__MODULE__, fn state ->
            %{state | checkpoints: Map.delete(state.checkpoints, key)}
          end)

          {:ok, %{rows: []}}

        String.contains?(sql, "delete from jido_cluster_thread_entries") ->
          Agent.update(__MODULE__, fn state ->
            %{state | entries: Map.delete(state.entries, key)}
          end)

          {:ok, %{rows: []}}

        String.contains?(sql, "delete from jido_cluster_thread_meta") ->
          Agent.update(__MODULE__, fn state ->
            %{state | meta: Map.delete(state.meta, key)}
          end)

          {:ok, %{rows: []}}

        String.contains?(sql, "select rev, created_at, updated_at, metadata") ->
          rows =
            Agent.get(__MODULE__, fn %{meta: meta} ->
              case Map.get(meta, key) do
                nil ->
                  []

                %{rev: rev, created_at: created_at, updated_at: updated_at, metadata: metadata} ->
                  [[rev, created_at, updated_at, metadata]]
              end
            end)

          {:ok, %{rows: rows}}

        String.contains?(sql, "select rev, created_at, metadata") and String.contains?(sql, "for update") ->
          rows =
            Agent.get(__MODULE__, fn %{meta: meta} ->
              case Map.get(meta, key) do
                nil -> []
                %{rev: rev, created_at: created_at, metadata: metadata} -> [[rev, created_at, metadata]]
              end
            end)

          {:ok, %{rows: rows}}

        String.contains?(sql, "select seq, kind, at, payload, refs") ->
          rows =
            Agent.get(__MODULE__, fn %{entries: entries} ->
              entries
              |> Map.get(key, %{})
              |> Enum.sort_by(fn {seq, _} -> seq end)
              |> Enum.map(fn {seq, %{kind: kind, at: at, payload: payload, refs: refs}} ->
                [seq, kind, at, payload, refs]
              end)
            end)

          {:ok, %{rows: rows}}

        true ->
          {:error, {:unsupported_query, sql, [key]}}
      end
    end

    defp handle_query(sql, [key, data]) do
      if String.contains?(sql, "insert into jido_cluster_checkpoints") do
        Agent.update(__MODULE__, fn state ->
          %{state | checkpoints: Map.put(state.checkpoints, key, data)}
        end)

        {:ok, %{rows: []}}
      else
        {:error, {:unsupported_query, sql, [key, data]}}
      end
    end

    defp handle_query(sql, [thread_id, seq, kind, at, payload, refs]) do
      if String.contains?(sql, "insert into jido_cluster_thread_entries") do
        Agent.get_and_update(__MODULE__, fn state ->
          thread_entries = Map.get(state.entries, thread_id, %{})

          if Map.has_key?(thread_entries, seq) do
            {{:error, :duplicate_entry}, state}
          else
            updated_thread_entries =
              Map.put(thread_entries, seq, %{kind: kind, at: at, payload: payload, refs: refs})

            new_state = %{state | entries: Map.put(state.entries, thread_id, updated_thread_entries)}
            {{:ok, %{rows: []}}, new_state}
          end
        end)
      else
        {:error, {:unsupported_query, sql, [thread_id, seq, kind, at, payload, refs]}}
      end
    end

    defp handle_query(sql, [thread_id, rev, metadata, created_at, updated_at]) do
      if String.contains?(sql, "insert into jido_cluster_thread_meta") do
        Agent.update(__MODULE__, fn state ->
          new_meta = %{rev: rev, metadata: metadata, created_at: created_at, updated_at: updated_at}
          %{state | meta: Map.put(state.meta, thread_id, new_meta)}
        end)

        {:ok, %{rows: []}}
      else
        {:error, {:unsupported_query, sql, [thread_id, rev, metadata, created_at, updated_at]}}
      end
    end
  end

  setup do
    start_supervised!(FakePostgresRepo)
    FakePostgresRepo.reset()
    :ok
  end

  defp opts do
    [repo: FakePostgresRepo]
  end

  test "checkpoint operations" do
    key = {:agent, "postgres-1"}
    data = %{value: 42}

    assert :not_found = Postgres.get_checkpoint(key, opts())
    assert :ok = Postgres.put_checkpoint(key, data, opts())
    assert {:ok, ^data} = Postgres.get_checkpoint(key, opts())
    assert :ok = Postgres.delete_checkpoint(key, opts())
    assert :not_found = Postgres.get_checkpoint(key, opts())
  end

  test "expected_rev conflict" do
    thread_id = "thread-#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             Postgres.append_thread(
               thread_id,
               [%{kind: :note, payload: %{n: 1}}],
               Keyword.put(opts(), :expected_rev, 0)
             )

    assert first.rev == 1

    assert {:error, :conflict} =
             Postgres.append_thread(
               thread_id,
               [%{kind: :note, payload: %{n: 2}}],
               Keyword.put(opts(), :expected_rev, 0)
             )
  end
end
