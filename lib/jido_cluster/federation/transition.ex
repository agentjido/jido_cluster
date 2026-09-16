defmodule Jido.Cluster.Federation.Transition do
  @moduledoc """
  Bounded prior-binding and resource retirement intent for a placement change.

  The deployment keeps its desired binding intent separately. This record retains
  the previous placement and bindings plus exact resource revisions to retire.
  It has only two phases: `retiring` and `retired`. Confirmed source mirror cleanup
  precedes the retired journal write and any Core movement. The record contains
  no process handles and cannot itself supply a runtime cleanup receipt.
  """
  alias Jido.Cluster.Federation.Intent

  @doc "Builds desired binding and retirement records from retained resource revisions."
  @spec new(map(), map(), [map()]) :: {:ok, map(), map()} | {:error, term()}
  def new(deployment, selected, resources) do
    old = deployment.federation

    with true <- old["phase"] == "ready",
         {:ok, next} <- Intent.new(deployment.instance, selected, deployment.activation, old["revision"] + 1),
         retired = Enum.sort_by(resources, &key/1),
         keys = Enum.map(retired, &key/1),
         true <- Enum.all?(old["mirrors"], &(key(&1) in keys)),
         true <- length(Enum.uniq(keys ++ Enum.map(next["mirrors"], &key/1))) <= 256 do
      mirrors =
        Enum.map(next["mirrors"], fn mirror ->
          prior = Enum.find(retired, &(key(&1) == key(mirror)))
          Map.put(mirror, "revision", successor(prior))
        end)

      transition = %{
        "version" => 1,
        "phase" => "retiring",
        "previous" => old,
        "from" => Map.new(deployment.selected, fn {k, host} -> {k, Atom.to_string(host)} end),
        "retire" => retired
      }

      next = %{next | "mirrors" => mirrors}

      with :ok <- Intent.validate(next, deployment.instance, selected, deployment.activation),
           do: {:ok, next, transition}
    else
      false -> {:error, :binding_transition_conflict}
      error -> error
    end
  end

  defp successor(nil), do: 0
  defp successor(prior), do: prior["revision"] + 1

  @doc "Validates a portable retirement record against both accepted placements."
  @spec validate(term(), map(), map(), [String.t()]) :: :ok | {:error, term()}
  def validate(nil, _, _, _), do: :ok

  def validate(record, deployment, previous_selected, hosts) when is_map(record) do
    with true <- Enum.sort(Map.keys(record)) == Enum.sort(~w(version phase previous from retire)),
         true <- record["version"] === 1 and record["phase"] in ~w(retiring retired),
         true <- record["from"] == Map.new(previous_selected, fn {key, host} -> {key, Atom.to_string(host)} end),
         :ok <- Intent.validate(record["previous"], deployment.instance, previous_selected, deployment.activation),
         true <- is_map(deployment.federation) and is_map(record["previous"]),
         true <- record["previous"]["phase"] == "ready",
         true <- deployment.federation["revision"] == record["previous"]["revision"] + 1,
         true <- valid_resources?(record["retire"], record["previous"], deployment.federation, hosts) do
      :ok
    else
      _ -> {:error, :invalid_binding_transition}
    end
  end

  def validate(_, _, _, _), do: {:error, :invalid_binding_transition}

  defp valid_resources?(records, previous, desired, hosts) when is_list(records) and length(records) <= 256 do
    channels = Enum.map(previous["mirrors"], & &1["channel"])

    Enum.all?(records, &resource?(&1, hosts, channels)) and
      records == Enum.sort_by(records, &key/1) and
      length(records) == length(Enum.uniq_by(records, &key/1)) and
      Enum.all?(previous["mirrors"], &(&1 in records)) and
      length(Enum.uniq_by(records ++ desired["mirrors"], &key/1)) <= 256 and
      Enum.all?(desired["mirrors"], &next_revision?(&1, records))
  end

  defp valid_resources?(_, _, _, _), do: false

  defp resource?(%{"host" => host, "channel" => channel, "revision" => revision} = r, hosts, channels) do
    map_size(r) == 3 and host in hosts and channel in channels and is_integer(revision) and
      revision in 0..9_007_199_254_740_991
  end

  defp resource?(_, _, _), do: false

  defp next_revision?(mirror, records) do
    case Enum.find(records, &(key(&1) == key(mirror))) do
      nil -> mirror["revision"] == 0
      old -> mirror["revision"] == old["revision"] + 1
    end
  end

  defp key(record), do: {record["host"], record["channel"]}
end
