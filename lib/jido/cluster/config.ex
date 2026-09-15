defmodule Jido.Cluster.Config do
  @moduledoc "Validated configuration for one V3 cluster manager."

  @enforce_keys [:name, :agent, :jido, :namespace]
  defstruct [
    :name,
    :agent,
    :jido,
    :namespace,
    :persistence,
    min_quorum_nodes: 1,
    idle_timeout: :infinity,
    agent_opts: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          agent: module(),
          jido: atom(),
          namespace: String.t(),
          persistence: Jido.Persistence.adapter_config(),
          min_quorum_nodes: pos_integer(),
          idle_timeout: pos_integer() | :infinity,
          agent_opts: keyword()
        }

  @keys [:name, :agent, :namespace, :persistence, :min_quorum_nodes, :idle_timeout, :agent_opts]
  @agent_keys [
    :turn_timeout,
    :directive_timeout,
    :readiness_timeout,
    :max_postponed_signals,
    :max_directives_per_turn,
    :error_policy,
    :debug,
    :debug_max_events
  ]

  @doc "Validates manager options. V2 options are rejected."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- @keys,
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         name when is_atom(name) and name not in [nil, true, false] <- Keyword.get(opts, :name),
         agent when is_atom(agent) and not is_nil(agent) <- Keyword.get(opts, :agent),
         true <- Code.ensure_loaded?(agent) and function_exported?(agent, :new, 0),
         namespace = Keyword.get(opts, :namespace, "jido-cluster/#{name}"),
         true <- is_binary(namespace) and byte_size(namespace) > 0,
         quorum = Keyword.get(opts, :min_quorum_nodes, 1),
         true <- is_integer(quorum) and quorum > 0,
         idle = Keyword.get(opts, :idle_timeout, :infinity),
         true <- idle == :infinity or (is_integer(idle) and idle > 0),
         agent_opts = Keyword.get(opts, :agent_opts, []),
         true <- is_list(agent_opts) and Keyword.keyword?(agent_opts),
         [] <- Keyword.keys(agent_opts) -- @agent_keys,
         {:ok, persistence} <- Jido.Persistence.resolve_config(Keyword.get(opts, :persistence), nil) do
      {:ok,
       %__MODULE__{
         name: name,
         agent: agent,
         jido: Module.concat(Jido.Cluster.Runtime, name),
         namespace: namespace,
         persistence: persistence,
         min_quorum_nodes: quorum,
         idle_timeout: idle,
         agent_opts: agent_opts
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_manager_options}
    end
  end

  def new(_), do: {:error, :invalid_manager_options}
end
