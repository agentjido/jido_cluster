defmodule JidoCluster.LeaseStore do
  @moduledoc false

  alias Jido.Cluster.{FenceToken, Lease, LeaseBackend}

  @type acquire_error :: :lease_unavailable | :stale | term()

  @spec acquire_or_renew(term(), term(), term(), LeaseBackend.t()) :: {:ok, Lease.t()} | {:error, acquire_error()}
  def acquire_or_renew(manager, key, claimant, %LeaseBackend{} = backend) do
    transact(backend, fn repo ->
      now_ms = System.system_time(:millisecond)
      storage_key = lease_key(backend.prefix, manager, key)

      case read_lease(repo, storage_key) do
        nil ->
          lease = build_new_lease(manager, key, claimant, 1, now_ms, backend)
          write_lease(repo, storage_key, lease)
          {:ok, lease}

        %Lease{} = lease ->
          cond do
            lease.holder == claimant and not Lease.expired?(lease, now_ms) and lease.status == :active ->
              renewed = %{lease | expires_at_ms: now_ms + backend.ttl_ms}
              write_lease(repo, storage_key, renewed)
              {:ok, renewed}

            lease.status in [:released, :expired] or Lease.expired?(lease, now_ms) ->
              next_epoch = lease.epoch + 1
              next_lease = build_new_lease(manager, key, claimant, next_epoch, now_ms, backend)
              write_lease(repo, storage_key, next_lease)
              {:ok, next_lease}

            true ->
              rollback(repo, :lease_unavailable)
          end
      end
    end)
  end

  @spec release(term(), term(), term(), LeaseBackend.t()) :: :ok | {:error, :stale | term()}
  def release(manager, key, claimant, %LeaseBackend{} = backend) do
    transact(backend, fn repo ->
      now_ms = System.system_time(:millisecond)
      storage_key = lease_key(backend.prefix, manager, key)

      case read_lease(repo, storage_key) do
        %Lease{holder: ^claimant} = lease ->
          released = %{lease | status: :released, expires_at_ms: now_ms}
          write_lease(repo, storage_key, released)
          :ok

        %Lease{} ->
          rollback(repo, :stale)

        nil ->
          :ok
      end
    end)
  end

  @spec current_holder(term(), term(), LeaseBackend.t()) :: {:ok, term() | nil} | {:error, term()}
  def current_holder(manager, key, %LeaseBackend{} = backend) do
    case transact(backend, fn repo ->
           now_ms = System.system_time(:millisecond)

           case read_lease(repo, lease_key(backend.prefix, manager, key)) do
             %Lease{status: :active} = lease ->
               if Lease.expired?(lease, now_ms), do: nil, else: lease.holder

             _ ->
               nil
           end
         end) do
      {:error, reason} -> {:error, reason}
      holder -> {:ok, holder}
    end
  end

  defp build_new_lease(manager, key, claimant, epoch, now_ms, %LeaseBackend{} = backend) do
    lease_id = unique_lease_id()

    fence_token =
      FenceToken.new!(
        epoch: epoch,
        lease_id: lease_id,
        holder: claimant,
        issued_at_ms: now_ms
      )

    Lease.new!(
      manager: manager,
      key: key,
      holder: claimant,
      lease_id: lease_id,
      epoch: epoch,
      issued_at_ms: now_ms,
      expires_at_ms: now_ms + backend.ttl_ms,
      ttl_ms: backend.ttl_ms,
      renew_interval_ms: backend.renew_interval_ms,
      status: :active,
      fence_token: fence_token
    )
  end

  defp unique_lease_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp lease_key(prefix, manager, key) do
    encoded =
      {manager, key}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    prefix <> encoded
  end

  defp read_lease(repo, storage_key) do
    case repo.get(storage_key) do
      nil -> nil
      binary -> :erlang.binary_to_term(binary, [:safe])
    end
  end

  defp write_lease(repo, storage_key, %Lease{} = lease) do
    :ok = repo.put(storage_key, :erlang.term_to_binary(lease))
  end

  defp transact(%LeaseBackend{repo: repo}, fun) when is_function(fun, 1) do
    case repo.transact(fn -> fun.(repo) end) do
      {:error, reason} -> {:error, reason}
      result -> result
    end
  rescue
    error -> {:error, error}
  catch
    :throw, {_module, :rollback, reason} -> {:error, reason}
    :throw, {:rollback_unavailable, reason} -> {:error, reason}
  end

  defp rollback(repo, reason) do
    if function_exported?(repo, :rollback, 1) do
      repo.rollback(reason)
    else
      throw({:rollback_unavailable, reason})
    end
  end
end
