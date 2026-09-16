defmodule Jido.Cluster.HostProvider.Config do
  @moduledoc false

  @doc "Resolves configured host providers without contacting external resources."
  @spec new(term(), [map()], term()) :: {:ok, map()} | {:error, term()}
  def new(providers, hosts, journal) when is_map(providers) and not is_struct(providers) do
    cond do
      map_size(providers) == 0 -> {:ok, %{}}
      journal == :memory -> {:error, :host_provider_requires_journal}
      true -> resolve(providers, MapSet.new(hosts, & &1.node))
    end
  end

  def new(_, _, _), do: {:error, :invalid_host_providers}

  defp resolve(providers, hosts) do
    Enum.reduce_while(providers, {:ok, %{}}, fn {host, opts}, {:ok, acc} ->
      with true <- MapSet.member?(hosts, host),
           {:ok, provider} <- provider(opts) do
        {:cont, {:ok, Map.put(acc, host, provider)}}
      else
        _ -> {:halt, {:error, :invalid_host_providers}}
      end
    end)
  end

  defp provider(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:adapter, :id, :ownership],
         id = opts[:id],
         true <- is_binary(id) and byte_size(id) in 1..256 and String.valid?(id),
         ownership when ownership in [:owned, :borrowed] <- opts[:ownership],
         {module, options} when is_atom(module) and is_list(options) <- opts[:adapter],
         true <- Keyword.keyword?(options) and Code.ensure_loaded?(module),
         true <- callbacks?(module),
         :ok <- module.validate_options(options) do
      {:ok, %{id: id, ownership: ownership, module: module, options: options}}
    else
      _ -> {:error, :invalid_provider}
    end
  rescue
    _ -> {:error, :invalid_provider}
  catch
    _, _ -> {:error, :invalid_provider}
  end

  defp provider(_), do: {:error, :invalid_provider}

  defp callbacks?(module),
    do:
      Enum.all?([validate_options: 1, acquire: 2, inspect: 2, release: 2], fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
end
