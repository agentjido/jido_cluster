defmodule Jido.Cluster.Journal.Definition do
  @moduledoc """
  Stores a topology definition and its input through trusted application IDs.

  Definition encoding uses the public core Topology Codec. Input atoms and static
  values use the same `Jido.Codec.Registry`. Applications supply stable, versioned
  identifiers and retain aliases needed by older records. This module never
  derives a temporary registry, creates atoms from stored strings, or stores a
  runtime plan, PID, function, reference, or Agent checkpoint.
  """
  alias Jido.Codec.Registry
  alias Jido.Topology.Codec

  @doc "Encodes an instance's definition and input without storing its runtime plan."
  @spec encode(Jido.Topology.Instance.t(), Registry.t() | map()) :: {:ok, map()} | {:error, term()}
  def encode(instance, registry) do
    with {:ok, registry} <- Registry.new(registry),
         {:ok, definition} <- Codec.encode(instance.definition, registry),
         {:ok, input} <- value(:encode, instance.input, registry, 0) do
      {:ok, %{"id" => instance.id, "definition" => definition, "input" => input}}
    end
  end

  @doc "Restores an instance through the supplied registry and core validation."
  @spec decode(map(), Registry.t() | map()) :: {:ok, Jido.Topology.Instance.t()} | {:error, term()}
  def decode(%{"id" => id, "definition" => definition, "input" => input} = document, registry)
      when map_size(document) == 3 and is_binary(id) do
    with {:ok, registry} <- Registry.new(registry),
         {:ok, input} <- value(:decode, input, registry, 0),
         do: Codec.decode(definition, registry, id: id, input: input)
  end

  def decode(_, _), do: {:error, :invalid_definition_record}

  defp value(_, _, _, depth) when depth > 32, do: {:error, :input_depth_limit}
  defp value(_, input, _, _) when is_number(input) or is_boolean(input) or is_nil(input), do: {:ok, input}
  defp value(:decode, input, _, _) when is_binary(input), do: {:ok, input}

  defp value(:encode, input, _, _) when is_binary(input) do
    if String.valid?(input), do: {:ok, input}, else: {:ok, %{"type" => "binary", "bytes" => Base.encode64(input)}}
  end

  defp value(:encode, input, registry, _) when is_atom(input), do: reference(registry, :atom, input)
  defp value(:encode, input, registry, _) when is_struct(input), do: reference(registry, :value, input)

  defp value(:encode, input, registry, depth) when is_map(input) do
    with {:ok, entries} <- traverse(Enum.sort(input), &encode_pair(&1, registry, depth)),
         do: {:ok, %{"type" => "map", "entries" => entries}}
  end

  defp value(:encode, input, registry, depth) when is_tuple(input),
    do: sequence("tuple", Tuple.to_list(input), registry, depth)

  defp value(:encode, input, registry, depth) when is_list(input),
    do: sequence("list", input, registry, depth)

  defp value(:decode, %{"type" => type, "id" => id} = input, registry, _)
       when map_size(input) == 2 and type in ["atom", "value"],
       do: Registry.resolve(registry, id, if(type == "atom", do: :atom, else: :value))

  defp value(:decode, %{"type" => "binary", "bytes" => bytes} = input, _, _)
       when map_size(input) == 2 and is_binary(bytes) do
    case Base.decode64(bytes) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_input_binary}
    end
  end

  defp value(:decode, %{"type" => type, "items" => items} = input, registry, depth)
       when map_size(input) == 2 and type in ["tuple", "list"] do
    with {:ok, items} <- traverse(items, &value(:decode, &1, registry, depth + 1)),
         do: {:ok, if(type == "tuple", do: List.to_tuple(items), else: items)}
  end

  defp value(:decode, %{"type" => "map", "entries" => entries} = input, registry, depth)
       when map_size(input) == 2 do
    with {:ok, pairs} <- traverse(entries, &decode_pair(&1, registry, depth)),
         map = Map.new(pairs),
         true <- map_size(map) == length(pairs) do
      {:ok, map}
    else
      false -> {:error, :duplicate_input_key}
      error -> error
    end
  end

  defp value(_, _, _, _), do: {:error, :non_portable_input}

  defp encode_pair({key, item}, registry, depth) do
    with {:ok, key} <- value(:encode, key, registry, depth + 1),
         {:ok, item} <- value(:encode, item, registry, depth + 1),
         do: {:ok, [key, item]}
  end

  defp decode_pair([key, item], registry, depth) do
    with {:ok, key} <- value(:decode, key, registry, depth + 1),
         {:ok, item} <- value(:decode, item, registry, depth + 1),
         do: {:ok, {key, item}}
  end

  defp decode_pair(_, _, _), do: {:error, :invalid_input_pair}

  defp reference(registry, kind, input) do
    with {:ok, id} <- Registry.identifier(registry, kind, input),
         do: {:ok, %{"type" => Atom.to_string(kind), "id" => id}}
  end

  defp sequence(type, input, registry, depth) do
    with {:ok, items} <- traverse(input, &value(:encode, &1, registry, depth + 1)),
         do: {:ok, %{"type" => type, "items" => items}}
  end

  defp traverse(items, fun) when is_list(items) and length(items) <= 10_000 do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp traverse(_, _), do: {:error, :invalid_input_collection}
end
