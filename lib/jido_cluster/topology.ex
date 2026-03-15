defmodule JidoCluster.Topology do
  @moduledoc """
  Cluster topology and deterministic ownership helpers.

  Ownership uses rendezvous hashing over `{manager, key, node}` for stable,
  deterministic placement with minimal remapping during node topology changes.
  """

  alias Jido.Cluster.Placement
  alias Jido.Cluster.Topology.View

  @doc "Returns connected nodes including `Node.self/0`, sorted deterministically."
  @spec connected_nodes() :: [node()]
  def connected_nodes do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Returns true when the connected node set satisfies the required quorum size."
  @spec quorum_met?(pos_integer(), [node()]) :: boolean()
  def quorum_met?(min_quorum_nodes, nodes \\ connected_nodes())
      when is_integer(min_quorum_nodes) and min_quorum_nodes > 0 and is_list(nodes) do
    length(nodes) >= min_quorum_nodes
  end

  @doc "Returns the deterministic leader node for the connected node set."
  @spec leader_node([node()]) :: node()
  def leader_node(nodes \\ connected_nodes())

  def leader_node([node | _rest]), do: node
  def leader_node([]), do: Node.self()

  @doc "Returns a topology snapshot for the currently connected nodes."
  @spec view([node()], pos_integer()) :: View.t()
  def view(nodes \\ connected_nodes(), min_quorum_nodes \\ 1) do
    normalized_nodes =
      nodes
      |> Enum.uniq()
      |> Enum.sort()

    View.new!(
      nodes: normalized_nodes,
      leader: leader_node(normalized_nodes),
      quorum_met?: quorum_met?(min_quorum_nodes, normalized_nodes),
      observed_at: System.system_time(:millisecond)
    )
  end

  @doc "Returns the owner node for the given manager and key."
  @spec owner_node(term(), term(), [node()]) :: node()
  def owner_node(manager, key, nodes)
      when is_list(nodes) and nodes != [] do
    placement(manager, key, nodes, 1).primary
  end

  def owner_node(manager, key, []) do
    owner_node(manager, key, connected_nodes())
  end

  @doc "Returns the deterministic placement for the given manager and key."
  @spec placement(term(), term(), [node()], pos_integer()) :: Placement.t()
  def placement(manager, key, nodes, count \\ 2)
      when is_list(nodes) and is_integer(count) and count > 0 do
    ordered_nodes =
      nodes
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.sort_by(&hash_score(manager, key, &1), :desc)
      |> Enum.take(count)

    Placement.new!(
      manager: manager,
      key: key,
      primary: List.first(ordered_nodes),
      standby: Enum.at(ordered_nodes, 1),
      nodes: ordered_nodes
    )
  end

  @doc "Returns the deterministic primary/standby node list for a key."
  @spec replica_nodes(term(), term(), [node()], pos_integer()) :: [node()]
  def replica_nodes(manager, key, nodes, count \\ 2)
      when is_list(nodes) and is_integer(count) and count > 0 do
    placement(manager, key, nodes, count).nodes
  end

  defp hash_score(manager, key, node) do
    bin = :erlang.term_to_binary({manager, key, node})

    <<score::unsigned-big-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, bin)
    score
  end
end
