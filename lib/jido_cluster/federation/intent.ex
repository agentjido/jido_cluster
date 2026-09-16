defmodule Jido.Cluster.Federation.Intent do
  @moduledoc """
  Portable binding intent for one deployment activation.

  A record contains declared logical IDs, Refs, root paths, accepted hosts,
  host incarnations, one binding revision, mirror resource revisions, and a
  pending lifecycle phase. It contains no PIDs, subscription IDs, or payloads.
  The journal owner must confirm each change before dependent runtime effects.
  A record alone never proves current attachment or permits replacement.

  Initial attachment uses `planned`, `attaching`, and `ready`. Stop retains the
  record as `detaching` until confirmed cleanup permits `stopped`. Recovery after
  exact activation cleanup creates a new activation record and advances the
  binding revision. Each new activation starts mirror resource revisions at zero.
  Binding revisions are integers from zero through 9,007,199,254,740,991.
  """
  alias Jido.Cluster.Federation.{Binding, Declarations}
  alias Jido.Topology.{Instance, Plan}

  @max_revision 9_007_199_254_740_991
  @phases ~w(planned attaching ready detaching stopped)

  @doc "Builds bounded initial intent without runtime or journal effects."
  @spec new(Instance.t(), map(), map(), non_neg_integer()) :: {:ok, map() | nil} | {:error, term()}
  def new(instance, selected, activation, revision \\ 0) do
    with true <- is_integer(revision) and revision in 0..@max_revision,
         {:ok, channels} <- Declarations.resolve(instance, activation.namespace) do
      build(channels, instance, selected, activation, revision)
    else
      false -> {:error, :binding_revision_limit}
      error -> error
    end
  end

  @doc "Validates identity, accepted placement, counts, phases, and portable values."
  @spec validate(term(), Instance.t(), map(), map()) :: :ok | {:error, term()}
  def validate(nil, instance, selected, activation) do
    case new(instance, selected, activation) do
      {:ok, nil} -> :ok
      _ -> {:error, :binding_intent_missing}
    end
  end

  def validate(%{"revision" => revision} = record, instance, selected, activation) do
    with {:ok, expected} when is_map(expected) <- new(instance, selected, activation, revision),
         true <- Enum.sort(Map.keys(record)) == Enum.sort(Map.keys(expected)),
         true <- record["version"] === 1 and record["activation"] == activation.id,
         true <- record["phase"] in @phases,
         true <- valid_bindings?(record, expected),
         true <- valid_mirrors?(record["mirrors"], expected["mirrors"]) do
      :ok
    else
      _ -> {:error, :invalid_binding_intent}
    end
  end

  def validate(_, _, _, _), do: {:error, :invalid_binding_intent}

  @doc "Records accepted host incarnations before attachment effects."
  @spec attaching(map(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def attaching(%{"phase" => phase} = intent, topology, claims) when phase in ~w(planned attaching ready) do
    with {:ok, bindings} <- bind_hosts(intent["bindings"], topology, claims) do
      phase = if phase == "ready", do: "ready", else: "attaching"
      {:ok, %{intent | "phase" => phase, "bindings" => bindings}}
    end
  end

  def attaching(_, _, _), do: {:error, :binding_intent_closed}

  @doc "Records required attachment completion after exact runtime receipts."
  @spec ready(map()) :: map()
  def ready(intent), do: %{intent | "phase" => "ready"}

  @doc "Retains binding identity while deployment stop cleanup is pending."
  @spec detaching(map() | nil) :: map() | nil
  def detaching(nil), do: nil
  def detaching(intent), do: %{intent | "phase" => "detaching"}

  @doc "Records confirmed deployment cleanup without deleting binding identity."
  @spec stopped(map() | nil) :: map() | nil
  def stopped(nil), do: nil
  def stopped(intent), do: %{intent | "phase" => "stopped"}

  @doc "Builds intent for a new activation after confirmed prior activation cleanup."
  @spec replacement(map()) :: {:ok, map() | nil} | {:error, term()}
  def replacement(deployment) do
    revision =
      case Map.get(deployment, :federation) do
        nil -> 0
        intent -> intent["revision"] + 1
      end

    new(deployment.instance, deployment.selected, deployment.activation, revision)
  end

  defp build([], _, _, _, _), do: {:ok, nil}

  defp build(channels, instance, selected, activation, revision) do
    locations =
      Map.new(instance.definition.agents, fn agent ->
        spec = Map.fetch!(instance.plan.agents, Plan.resolve(instance.plan, agent.key, :agent))
        {spec.id, %{path: [agent.key], host: Map.fetch!(selected, agent.key)}}
      end)

    bindings =
      for channel <- channels, binding <- channel.bindings do
        location = Map.fetch!(locations, binding.ref.id)

        %{
          "id" => Binding.id(channel.scope, binding.ref),
          "ref" => binding.ref.id,
          "path" => location.path,
          "channel" => elem(channel.scope, 2),
          "host" => Atom.to_string(location.host),
          "incarnation" => nil,
          "required" => binding.required
        }
      end

    mirrors =
      for channel <- channels,
          host <-
            Enum.uniq([activation.node | for(b <- bindings, b["channel"] == elem(channel.scope, 2), do: b["host"])]) do
        %{"host" => host, "channel" => elem(channel.scope, 2), "revision" => 0}
      end

    if length(mirrors) <= 256 do
      {:ok,
       %{
         "version" => 1,
         "activation" => activation.id,
         "revision" => revision,
         "phase" => "planned",
         "bindings" => Enum.sort_by(bindings, & &1["id"]),
         "mirrors" => Enum.sort_by(mirrors, &{&1["host"], &1["channel"]})
       }}
    else
      {:error, :binding_mirror_limit}
    end
  end

  defp valid_bindings?(%{"bindings" => bindings, "phase" => phase}, expected) when is_list(bindings) do
    length(bindings) == length(expected["bindings"]) and
      Enum.zip(bindings, expected["bindings"])
      |> Enum.all?(fn {actual, template} ->
        is_map(actual) and Map.has_key?(actual, "incarnation") and Map.put(actual, "incarnation", nil) == template and
          valid_incarnation?(actual["incarnation"], phase)
      end)
  end

  defp valid_bindings?(_, _), do: false
  defp valid_incarnation?(nil, phase), do: phase in ~w(planned detaching stopped)
  defp valid_incarnation?(value, _), do: is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value)

  defp valid_mirrors?(mirrors, expected) when is_list(mirrors) do
    length(mirrors) == length(expected) and
      Enum.zip(mirrors, expected)
      |> Enum.all?(fn {actual, template} ->
        is_map(actual) and Map.put(actual, "revision", 0) == template and
          is_integer(actual["revision"]) and actual["revision"] in 0..@max_revision
      end)
  end

  defp valid_mirrors?(_, _), do: false

  defp bind_hosts(bindings, topology, claims) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, acc} ->
      claim =
        Enum.find(
          claims,
          &(&1.topology_id == topology and &1.ref.id == binding["ref"] and
              Atom.to_string(&1.host) == binding["host"])
        )

      case bind_host(binding, claim) do
        {:ok, accepted} -> {:cont, {:ok, acc ++ [accepted]}}
        error -> {:halt, error}
      end
    end)
  end

  defp bind_host(binding, %{host_incarnation: incarnation, state: state})
       when is_binary(incarnation) and state in [:reserved, :active] do
    if binding["incarnation"] in [nil, incarnation],
      do: {:ok, Map.put(binding, "incarnation", incarnation)},
      else: {:error, :binding_incarnation_changed}
  end

  defp bind_host(_, _), do: {:error, :binding_host_unconfirmed}
end
