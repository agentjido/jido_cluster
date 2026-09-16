defmodule Jido.Cluster.Instance.Config do
  @moduledoc "Validated configuration for a named deployment service."

  alias Jido.Cluster.{Admission, Journal}
  alias Jido.Cluster.Federation.Limits
  alias Jido.Cluster.HostProvider.Config, as: ProviderConfig
  alias Jido.Persistence.Store

  defstruct [
    :name,
    :otp_app,
    :jido,
    :namespace,
    :scope,
    :mode,
    :journal,
    :registry,
    :agent_persistence,
    :federation,
    host_providers: %{},
    pools: [],
    hosts: [],
    timeout: 5_000
  ]

  @type t :: %__MODULE__{}
  @keys [
    :otp_app,
    :jido,
    :namespace,
    :scope,
    :journal,
    :registry,
    :agent_persistence,
    :federation,
    :pools,
    :timeout,
    :host_providers
  ]

  @doc "Combines and validates module defaults, application configuration, and start overrides."
  @spec new(module(), keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(name, defaults, overrides) do
    app = Keyword.get(defaults, :otp_app)
    configured = if is_atom(app) and not is_nil(app), do: Application.get_env(app, name, []), else: []

    with true <- Enum.all?([defaults, configured, overrides], &valid_options?/1),
         true <- is_atom(app) and app not in [nil, true, false],
         opts = defaults |> Keyword.merge(configured) |> Keyword.merge(overrides),
         {:ok, mode, jido, namespace} <- core(name, opts),
         scope = Keyword.get(opts, :scope, "default"),
         true <- nonempty?(scope),
         timeout = Keyword.get(opts, :timeout, 5_000),
         true <- is_integer(timeout) and timeout > 0,
         {:ok, hosts} <- pools(Keyword.get(opts, :pools, [])),
         {:ok, journal} <- journal(Keyword.get(opts, :journal, {Jido.Persistence.Bedrock, []})),
         {:ok, providers} <-
           ProviderConfig.new(Keyword.get(opts, :host_providers, %{}), hosts, journal),
         {:ok, registry} <- registry(journal, Keyword.get(opts, :registry)),
         {:ok, persistence} <- Jido.Persistence.resolve_config(Keyword.get(opts, :agent_persistence), nil),
         {:ok, federation} <- Limits.new(Keyword.get(opts, :federation, [])),
         true <- mode == :managed or not Keyword.has_key?(opts, :agent_persistence) do
      {:ok,
       %__MODULE__{
         name: name,
         otp_app: app,
         jido: jido,
         namespace: namespace,
         scope: scope,
         mode: mode,
         journal: journal,
         registry: registry,
         agent_persistence: persistence,
         federation: federation,
         host_providers: providers,
         pools: Keyword.get(opts, :pools, []),
         hosts: hosts,
         timeout: timeout
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_instance_options}
    end
  end

  defp valid_options?(opts) do
    is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- @keys == [] and
      length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0)))
  end

  defp core(name, opts) do
    if Keyword.has_key?(opts, :jido) do
      attached(Keyword.get(opts, :jido), Keyword.get(opts, :namespace))
    else
      namespace = Keyword.get(opts, :namespace, "jido-cluster/#{name}")

      if nonempty?(namespace),
        do: {:ok, :managed, Module.concat(name, Core), namespace},
        else: {:error, :invalid_namespace}
    end
  end

  defp attached(jido, namespace) when is_atom(jido) and jido not in [nil, true, false] do
    actual = Jido.namespace(jido)

    cond do
      is_nil(Process.whereis(jido)) or not nonempty?(actual) -> {:error, :jido_not_started}
      namespace != nil and namespace != actual -> {:error, :namespace_conflict}
      true -> {:ok, :attached, jido, actual}
    end
  end

  defp attached(_, _), do: {:error, :invalid_instance_options}

  defp pools(pools) do
    with true <- is_list(pools) and Keyword.keyword?(pools),
         true <-
           Enum.all?(pools, fn {_name, opts} ->
             is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) == [:hosts] and is_list(opts[:hosts])
           end),
         hosts = Enum.flat_map(pools, fn {_name, opts} -> Keyword.fetch!(opts, :hosts) end),
         {:ok, ledger} <- Admission.new(:configuration, hosts),
         true <- map_size(ledger.hosts) <= Journal.limits().hosts do
      {:ok, ledger.hosts |> Map.values() |> Enum.sort_by(& &1.node)}
    else
      _ -> {:error, :invalid_pools}
    end
  end

  defp journal(:memory), do: {:ok, :memory}

  defp journal(value) do
    case Store.open(value) do
      {:error, :persistence_not_configured} -> {:error, {:invalid_journal, :adapter_required}}
      {:ok, adapter} -> {:ok, adapter}
      {:error, reason} -> {:error, {:invalid_journal, reason}}
    end
  end

  defp registry(:memory, nil), do: {:ok, nil}
  defp registry(_, nil), do: {:error, {:invalid_registry, :required}}

  defp registry(_, value) do
    case Jido.Codec.Registry.new(value) do
      {:ok, registry} -> {:ok, registry}
      {:error, reason} -> {:error, {:invalid_registry, reason}}
    end
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
end
