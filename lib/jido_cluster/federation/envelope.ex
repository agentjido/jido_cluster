defmodule Jido.Cluster.Federation.Envelope do
  @moduledoc """
  One-hop federation envelope that retains the original Signal unchanged.

  Export identity is separate from Signal identity: publishing the same Signal
  twice creates two exports. A receiver can suppress a repeated export within
  its bounded cache window. There is no global exactly-once promise.

  Connected BEAM transport carries this term without JSON conversion. Payload
  atoms and binary data remain unchanged. Runtime values such as PIDs, references,
  and functions are rejected. No external term is decoded by this module.
  """

  alias Jido.Cluster.Federation.Limits
  alias Jido.Signal

  @type scope :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{
          scope: scope(),
          generation: String.t(),
          export_id: String.t(),
          signal: Signal.t(),
          hops: 1
        }
  @enforce_keys [:scope, :generation, :export_id, :signal]
  defstruct [:scope, :generation, :export_id, :signal, hops: 1]

  @doc "Builds a fresh explicit export after checking the complete envelope budget."
  @spec new(scope(), String.t(), Signal.t(), Limits.t()) :: {:ok, t()} | {:error, atom()}
  def new(scope, generation, %Signal{} = signal, %Limits{} = limits) do
    envelope = %__MODULE__{scope: scope, generation: generation, export_id: Signal.ID.generate!(), signal: signal}
    with {:ok, _} <- validate(envelope, scope, [signal.type], limits), do: {:ok, envelope}
  end

  def new(_, _, _, _), do: {:error, :invalid_signal}

  @doc "Checks received scope, exact type, hop count, and size before queue admission."
  @spec validate(term(), scope(), [String.t()], Limits.t()) :: {:ok, Signal.t()} | {:error, atom()}
  def validate(%__MODULE__{} = envelope, scope, types, %Limits{} = limits) when is_list(types) do
    cond do
      not valid_scope?(scope) or envelope.scope != scope -> {:error, :invalid_envelope_scope}
      not header?(envelope) -> {:error, :invalid_envelope_header}
      bytes(envelope) > limits.max_envelope_bytes -> {:error, :envelope_too_large}
      not match?(%Signal{}, envelope.signal) -> {:error, :invalid_signal}
      envelope.signal.type not in types -> {:error, :type_not_allowed}
      true -> valid_signal(envelope.signal)
    end
  end

  def validate(_, _, _, _), do: {:error, :invalid_envelope}

  @doc "Returns the duplicate-suppression identity within this envelope's channel."
  @spec identity(t()) :: {String.t(), String.t()}
  def identity(envelope), do: {envelope.generation, envelope.export_id}

  @doc "Measures the full uncompressed external-term size used for byte admission."
  @spec bytes(t()) :: non_neg_integer()
  def bytes(envelope), do: :erlang.external_size(envelope)

  defp valid_signal(signal) do
    with :ok <- Jido.Action.validate_static_data(signal),
         {:ok, ^signal} <- Zoi.parse(Signal.schema(), signal) do
      {:ok, signal}
    else
      {:error, reason} when is_binary(reason) -> {:error, :non_portable_signal}
      _ -> {:error, :invalid_signal}
    end
  end

  defp header?(envelope),
    do:
      map_size(envelope) == 6 and envelope.hops == 1 and text?(envelope.generation, 128) and
        text?(envelope.export_id, 128)

  defp valid_scope?({namespace, topology, channel}),
    do: text?(namespace, 1024) and text?(topology, 1024) and text?(channel, 128)

  defp valid_scope?(_), do: false
  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
end
