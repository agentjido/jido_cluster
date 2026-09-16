defmodule Jido.Cluster.HostProvider.Step do
  @moduledoc """
  Bounded durable identity for one host acquisition attempt.

  `host` and `provider` identify configured inventory and adapter entries. They
  are strings, not provider credentials or dynamically decoded BEAM atoms.
  `id` belongs to one recorded attempt and remains unchanged after a lost reply.
  """

  @enforce_keys [:namespace, :scope, :host, :provider, :id]
  defstruct @enforce_keys
  @fields [:namespace, :scope, :host, :provider, :id]
  @type t :: %__MODULE__{
          namespace: String.t(),
          scope: String.t(),
          host: String.t(),
          provider: String.t(),
          id: String.t()
        }

  @doc "Validates a complete bounded step without runtime values or extra fields."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_host_step}
  def new(values) when is_map(values) and not is_struct(values) do
    if Enum.sort(Map.keys(values)) == Enum.sort(@fields) and Enum.all?(Map.values(values), &identifier?/1),
      do: {:ok, struct!(__MODULE__, values)},
      else: {:error, :invalid_host_step}
  end

  def new(_), do: {:error, :invalid_host_step}

  @doc "Encodes the exact step fields as a portable journal object."
  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = step),
    do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(step, &1)})

  @doc "Reads only known step fields without creating atoms."
  @spec from_record(term()) :: {:ok, t()} | {:error, :invalid_host_step}
  def from_record(record) when is_map(record) and not is_struct(record) do
    if Enum.sort(Map.keys(record)) == Enum.sort(Enum.map(@fields, &Atom.to_string/1)),
      do: new(Map.new(@fields, &{&1, record[Atom.to_string(&1)]})),
      else: {:error, :invalid_host_step}
  end

  def from_record(_), do: {:error, :invalid_host_step}

  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
