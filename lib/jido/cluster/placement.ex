defmodule Jido.Cluster.Placement do
  @moduledoc "Pure label-based selection from an application-supplied host inventory."
  alias Jido.Cluster.Topology

  @type host :: %{node: node(), labels: [String.t()], available: boolean()}

  @doc "Selects a compatible available host using deterministic rendezvous hashing."
  @spec select(term(), [host()], [String.t()]) :: {:ok, node()} | {:error, atom()}
  def select(key, hosts, labels \\ []) do
    cond do
      not valid_labels?(labels) -> {:error, :invalid_requirements}
      not valid_hosts?(hosts) -> {:error, :invalid_inventory}
      true -> choose(key, hosts, labels)
    end
  end

  @doc "Rejects remote placement for an Agent that subscribes to a Controller-local Bus."
  @spec locality(map(), node(), node()) :: :ok | {:error, :local_bus_requires_controller_node}
  def locality(%{subscriptions: []}, _target, _controller), do: :ok
  def locality(_spec, same, same), do: :ok
  def locality(_spec, _target, _controller), do: {:error, :local_bus_requires_controller_node}

  defp choose(key, hosts, labels) do
    nodes =
      hosts
      |> Enum.filter(fn host -> host.available and Enum.all?(labels, fn label -> label in host.labels end) end)
      |> Enum.map(& &1.node)

    case nodes do
      [] -> {:error, :no_eligible_node}
      _ -> {:ok, Topology.owner_node(__MODULE__, key, nodes)}
    end
  end

  defp valid_hosts?(hosts) when is_list(hosts) do
    Enum.all?(hosts, &valid_host?/1) and length(hosts) == length(Enum.uniq_by(hosts, & &1.node))
  end

  defp valid_hosts?(_), do: false

  defp valid_host?(%{node: worker, labels: labels, available: available}) do
    is_atom(worker) and worker not in [nil, true, false] and is_boolean(available) and valid_labels?(labels)
  end

  defp valid_host?(_), do: false

  defp valid_labels?(labels) when is_list(labels),
    do: Enum.all?(labels, &(is_binary(&1) and byte_size(&1) > 0))

  defp valid_labels?(_), do: false
end
