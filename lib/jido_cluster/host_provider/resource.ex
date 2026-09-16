defmodule Jido.Cluster.HostProvider.Resource do
  @moduledoc """
  Provider observation tied to one step and an exact resource incarnation.

  Resource state is distinct from connected BEAM readiness and Agent readiness.
  The resource ID and incarnation must come from inspection of the actual
  provider resource. A familiar name or ownership label alone is insufficient.
  """
  alias Jido.Cluster.HostProvider.Step

  @enforce_keys [:step, :id, :incarnation, :state]
  defstruct @enforce_keys
  @states [:starting, :running, :stopped]
  @type t :: %__MODULE__{
          step: Step.t(),
          id: String.t(),
          incarnation: String.t(),
          state: :starting | :running | :stopped
        }

  @doc "Builds a bounded observation with exact provider identity."
  @spec new(Step.t(), String.t(), String.t(), atom()) :: {:ok, t()} | {:error, :invalid_host_resource}
  def new(%Step{} = step, id, incarnation, state) do
    with {:ok, ^step} <- Step.new(Map.from_struct(step)),
         true <- identifier?(id) and identifier?(incarnation) and state in @states do
      {:ok, %__MODULE__{step: step, id: id, incarnation: incarnation, state: state}}
    else
      _ -> {:error, :invalid_host_resource}
    end
  end

  def new(_, _, _, _), do: {:error, :invalid_host_resource}

  @doc "Compares immutable ownership coordinates independently of observed state."
  @spec same?(t(), t()) :: boolean()
  def same?(%__MODULE__{} = first, %__MODULE__{} = second),
    do: first.step == second.step and first.id == second.id and first.incarnation == second.incarnation

  @doc "Encodes an observation without runtime options or provider credentials."
  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = resource) do
    %{
      "step" => Step.to_record(resource.step),
      "id" => resource.id,
      "incarnation" => resource.incarnation,
      "state" => Atom.to_string(resource.state)
    }
  end

  @doc "Validates a portable observation using only known state atoms."
  @spec from_record(term()) :: {:ok, t()} | {:error, :invalid_host_resource}
  def from_record(record) when is_map(record) and not is_struct(record) do
    with true <- Enum.sort(Map.keys(record)) == ~w(id incarnation state step),
         {:ok, step} <- Step.from_record(record["step"]),
         state when not is_nil(state) <- Enum.find(@states, &(Atom.to_string(&1) == record["state"])) do
      new(step, record["id"], record["incarnation"], state)
    else
      _ -> {:error, :invalid_host_resource}
    end
  end

  def from_record(_), do: {:error, :invalid_host_resource}
  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
