defmodule Jido.Cluster.HostSession do
  @moduledoc """
  Durable intent and evidence for one configured host's provider lifecycle.

  The step remains stable through inspection and release. The scope journal owns
  this record; it is not a second claim ledger. `attempted` is recorded before
  acquisition can run, so a restart cannot mistake an unknown external call for
  an unused attempt. Resource state and directly probed host incarnation remain
  separate. Runtime provider options and task PIDs never enter this record.
  """

  alias Jido.Cluster.HostProvider.{Resource, Step}
  @phases [:planned, :acquiring, :acquired, :ready, :releasing, :deleting, :released, :retained, :uncertain, :failed]
  @fields ~w(step ownership desired resource phase attempted host_incarnation operation reason)
  @enforce_keys [:step, :ownership, :operation]
  defstruct @enforce_keys ++
              [desired: :running, resource: nil, phase: :planned, attempted: false, host_incarnation: nil, reason: nil]

  @type t :: %__MODULE__{}

  @doc "Creates an unused acquisition intent for one configured host."
  @spec new(Step.t(), :owned | :borrowed, String.t()) :: {:ok, t()} | {:error, :invalid_host_session}
  def new(step, ownership, operation) do
    session = %__MODULE__{step: step, ownership: ownership, operation: operation}
    with :ok <- validate(session), do: {:ok, session}
  end

  @doc "Validates portable fields and required phase evidence."
  @spec validate(term()) :: :ok | {:error, :invalid_host_session}
  def validate(%__MODULE__{step: %Step{} = step} = session) do
    with {:ok, ^step} <- Step.new(Map.from_struct(step)),
         true <- session.ownership in [:owned, :borrowed] and session.desired in [:running, :released],
         true <- session.phase in @phases and is_boolean(session.attempted),
         true <- identifier?(session.operation) and optional_identifier?(session.host_incarnation),
         true <-
           is_nil(session.reason) or
             (is_binary(session.reason) and byte_size(session.reason) <= 512 and String.valid?(session.reason)),
         true <- resource?(session.resource, step),
         true <- phase?(session) do
      :ok
    else
      _ -> {:error, :invalid_host_session}
    end
  end

  def validate(_), do: {:error, :invalid_host_session}

  @doc "Encodes a validated session without execution handles."
  @spec to_record(t()) :: {:ok, map()} | {:error, :invalid_host_session}
  def to_record(session) do
    with :ok <- validate(session) do
      {:ok,
       %{
         "step" => Step.to_record(session.step),
         "ownership" => Atom.to_string(session.ownership),
         "desired" => Atom.to_string(session.desired),
         "resource" => if(session.resource, do: Resource.to_record(session.resource)),
         "phase" => Atom.to_string(session.phase),
         "attempted" => session.attempted,
         "host_incarnation" => session.host_incarnation,
         "operation" => session.operation,
         "reason" => session.reason
       }}
    end
  end

  @doc "Restores known data fields without creating atoms or granting authority."
  @spec from_record(term()) :: {:ok, t()} | {:error, :invalid_host_session}
  def from_record(record) when is_map(record) and not is_struct(record) do
    with true <- Enum.sort(Map.keys(record)) == Enum.sort(@fields),
         {:ok, step} <- Step.from_record(record["step"]),
         {:ok, resource} <- read_resource(record["resource"]) do
      session = %__MODULE__{
        step: step,
        resource: resource,
        ownership: enum(record["ownership"], [:owned, :borrowed]),
        desired: enum(record["desired"], [:running, :released]),
        phase: enum(record["phase"], @phases),
        attempted: record["attempted"],
        host_incarnation: record["host_incarnation"],
        operation: record["operation"],
        reason: record["reason"]
      }

      with :ok <- validate(session), do: {:ok, session}
    else
      _ -> {:error, :invalid_host_session}
    end
  end

  def from_record(_), do: {:error, :invalid_host_session}
  defp enum(value, values), do: Enum.find(values, &(Atom.to_string(&1) == value))
  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
  defp optional_identifier?(nil), do: true
  defp optional_identifier?(value), do: identifier?(value)
  defp read_resource(nil), do: {:ok, nil}
  defp read_resource(record), do: Resource.from_record(record)
  defp resource?(nil, _), do: true

  defp resource?(%Resource{step: step} = resource, step),
    do: Resource.new(step, resource.id, resource.incarnation, resource.state) == {:ok, resource}

  defp resource?(_, _), do: false
  defp phase?(%{phase: :planned} = s), do: not s.attempted and is_nil(s.resource) and s.desired == :running
  defp phase?(%{phase: :acquiring} = s), do: s.attempted and is_nil(s.resource) and s.desired == :running
  defp phase?(%{phase: :acquired} = s), do: s.resource != nil and s.desired == :running

  defp phase?(%{phase: :ready} = s),
    do: match?(%Resource{state: :running}, s.resource) and identifier?(s.host_incarnation) and s.desired == :running

  defp phase?(%{phase: :released} = s), do: s.ownership == :owned and s.resource != nil and s.desired == :released
  defp phase?(%{phase: :retained} = s), do: s.ownership == :borrowed and s.desired == :released
  defp phase?(%{phase: :releasing} = s), do: s.desired == :released
  defp phase?(%{phase: :deleting} = s), do: s.desired == :released and s.resource != nil
  defp phase?(%{phase: :failed} = s), do: is_nil(s.resource)
  defp phase?(%{phase: :uncertain}), do: true
end
