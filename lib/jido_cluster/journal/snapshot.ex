defmodule Jido.Cluster.Journal.Snapshot do
  @moduledoc """
  Converts bounded service intent to a portable scope record.

  The record contains definitions, request identity, operations, claims, and
  complete drain transitions and declared binding lifecycle intent. It omits
  runtime processes and Agent checkpoints. Version-1 records without the binding
  field restore declarations as planned intent; they do not infer live attachment.
  Decoding does not grant authority or start work. Recovery must still confirm a
  journal revision and reconcile the retained claims before any external effect.

  Nodes are resolved only from the supplied host inventory. Definition IDs use
  the application's trusted registry. Stored reasons are bounded observations;
  they are restored as `{:recorded_reason, text}`, never as executable terms.
  """
  alias Jido.Cluster.{Admission, Journal}
  alias Jido.Cluster.Federation.Intent
  alias Jido.Cluster.Journal.{Definition, HostSessions, Snapshot.Reader}

  @doc "Encodes durable state with admission or observation size limits."
  @spec encode(map(), term(), :admission | :observation) :: {:ok, map()} | {:error, term()}
  def encode(state, registry, stage \\ :admission) when stage in [:admission, :observation] do
    with {:ok, deployments} <- deployments(state.deployments, registry),
         {:ok, sessions} <- HostSessions.encode(Map.get(state, :host_sessions, %{}), state.config) do
      document = %{
        "version" => 1,
        "namespace" => state.config.namespace,
        "scope" => state.config.scope,
        "generation" => state.generation,
        "epoch" => state.epoch,
        "host_providers" => HostSessions.providers(state.config),
        "host_sessions" => sessions,
        "hosts" => state.ledger.hosts |> Enum.sort() |> Enum.map(fn {_, host} -> host_record(host) end),
        "excluded" => state.ledger.excluded |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
        "claims" => state.ledger |> Admission.claims() |> Enum.map(&claim/1),
        "deployments" => deployments,
        "operations" => state.operations |> Enum.sort() |> Enum.map(fn {_, op} -> operation(op) end),
        "requests" => state.requests |> Enum.sort() |> Enum.map(&request/1)
      }

      with :ok <- size(document, stage),
           {:ok, _} <- decode(document, state.config, registry),
           do: {:ok, document}
    end
  end

  @doc "Validates a stored record and restores intent without runtime handles."
  @spec decode(map(), map(), term()) :: {:ok, map()} | {:error, term()}
  def decode(document, config, registry), do: Reader.decode(document, config, registry)

  @doc "Hashes portable request intent instead of a node's expanded runtime plan."
  @spec fingerprint(:deploy | :stop | :drain | :enable_host | :acquire_host | :release_host, term(), term()) ::
          {:ok, binary()} | {:error, term()}
  def fingerprint(:deploy, %Jido.Topology.Instance{} = instance, registry) do
    with {:ok, definition} <- Definition.encode(instance, registry), do: digest(["deploy", definition])
  end

  def fingerprint(:stop, id, _) when is_binary(id), do: digest(["stop", id])

  def fingerprint(action, host, _)
      when action in [:drain, :enable_host, :acquire_host, :release_host] and is_atom(host),
      do: digest([Atom.to_string(action), Atom.to_string(host)])

  def fingerprint(_, _, _), do: {:error, :invalid_request}

  defp digest(value), do: {:ok, :crypto.hash(:sha256, Jason.encode!(canonical(value)))}
  # JSON object order is not identity. Convert objects to sorted key/value lists
  # with explicit tags before hashing. No runtime term enters the fingerprint.
  defp canonical(value) when is_map(value),
    do: ["object", value |> Enum.sort() |> Enum.map(fn {key, item} -> [key, canonical(item)] end)]

  defp canonical(value) when is_list(value), do: ["array", Enum.map(value, &canonical/1)]
  defp canonical(value), do: ["scalar", value]

  defp deployments(deployments, registry) do
    Enum.reduce_while(Enum.sort(deployments), {:ok, []}, fn {_id, d}, {:ok, acc} ->
      with {:ok, definition} <- Definition.encode(d.instance, registry),
           {:ok, federation} <- federation(d) do
        record = %{
          "definition" => definition,
          "federation" => federation,
          "federation_transition" => Map.get(d, :federation_transition),
          "activation" => Map.new(d.activation, fn {key, value} -> {Atom.to_string(key), value} end),
          "recovery" => Atom.to_string(Map.get(d, :recovery, :idle)),
          "recovery_hosts" =>
            Map.new(Map.get(d, :recovery_hosts, %{}), fn {host, incarnation} ->
              {Atom.to_string(host), incarnation}
            end),
          "selected" => placement(d.selected),
          "initial_selected" => placement(Map.get(d, :initial_selected, d.selected)),
          "desired" => Atom.to_string(d.desired),
          "phase" => Atom.to_string(d.phase),
          "reason" => reason(d.reason),
          "operation" => d.operation,
          "prior_phase" => optional_atom(Map.get(d, :prior_phase))
        }

        {:cont, {:ok, [record | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp federation(%{federation: intent} = d) do
    with :ok <- Intent.validate(intent, d.instance, d.selected, d.activation), do: {:ok, intent}
  end

  defp federation(d), do: Intent.new(d.instance, d.selected, d.activation)

  defp host_record(host),
    do: %{
      "node" => Atom.to_string(host.node),
      "capacity" => host.capacity,
      "labels" => Enum.sort(host.labels),
      "available" => host.available,
      "allocation" => host.allocation
    }

  defp claim(claim),
    do: %{
      "topology" => claim.topology_id,
      "ref" => claim.ref.id,
      "host" => Atom.to_string(claim.host),
      "allocation" => claim.allocation,
      "incarnation" => claim.host_incarnation,
      "operation" => claim.operation_id,
      "state" => Atom.to_string(claim.state)
    }

  defp operation(op) do
    %{
      "id" => op.id,
      "attempt" => op.attempt_id,
      "action" => Atom.to_string(op.action),
      "topology" => op.topology_id,
      "phase" => Atom.to_string(op.phase),
      "reason" => reason(op.reason),
      "host" => optional_atom(Map.get(op, :host)),
      "steps" => op |> Map.get(:steps, %{}) |> Enum.sort() |> Enum.map(&step/1)
    }
  end

  defp step({id, step}),
    do: %{
      "topology" => id,
      "operation" => step.operation_id,
      "phase" => Atom.to_string(step.phase),
      "selected" => placement(step.selected),
      "arrivals" => placement(step.arrivals),
      "retired" => step.retired |> Enum.sort() |> Enum.map(fn {ref, host} -> [ref.id, Atom.to_string(host)] end)
    }

  defp request({token, {fingerprint, operation}}),
    do: %{"nonce" => token.nonce, "fingerprint" => Base.encode16(fingerprint, case: :lower), "operation" => operation}

  defp placement(selected), do: Map.new(selected, fn {key, node} -> {key, Atom.to_string(node)} end)
  defp optional_atom(nil), do: nil
  defp optional_atom(atom), do: Atom.to_string(atom)
  defp reason(nil), do: nil
  defp reason({:recorded_reason, text}) when is_binary(text), do: bounded_text(text)

  defp reason(term) do
    # Inspect bounds collection traversal; the final byte cap also bounds long
    # binaries and multi-byte text. The trailing partial UTF-8 codepoint is lost.
    term |> inspect(limit: 16, printable_limit: 128, structs: false) |> bounded_text()
  end

  defp bounded_text(text) do
    text
    |> String.codepoints()
    |> Enum.reduce_while("", fn point, acc ->
      if byte_size(acc) + byte_size(point) <= 512, do: {:cont, acc <> point}, else: {:halt, acc}
    end)
  end

  defp size(document, stage) do
    limit = if stage == :admission, do: Journal.limits().admission_bytes, else: Journal.limits().record_bytes
    # Reserve envelope space, including escaped namespace and scope strings.
    bytes =
      byte_size(Jason.encode!(document)) + 1024 + byte_size(Jason.encode!([document["namespace"], document["scope"]]))

    if bytes <= limit, do: :ok, else: {:error, {:aggregate_too_large, bytes, limit}}
  end
end
