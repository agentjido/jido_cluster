defmodule Jido.Cluster.Federation.Channel do
  @moduledoc "Validates the shared static contract of a host-local federation channel."
  alias Jido.Cluster.Federation.{Declarations, Envelope, Limits}

  @doc "Validates scope, exact Signal types, and concrete capacity limits without starting resources."
  @spec validate(Envelope.scope(), [String.t()], Limits.t()) :: :ok | {:error, :invalid_channel}
  def validate({_, _, key} = scope, types, %Limits{} = limits) do
    definition = %{
      agents: [],
      metadata: %{
        "jido.cluster.federation" => %{
          "version" => 1,
          "channels" => [%{"key" => key, "types" => types}],
          "bindings" => []
        }
      }
    }

    with {:ok, ^limits} <- Limits.new(Map.to_list(Map.from_struct(limits))),
         {:ok, _} <- Declarations.read(definition),
         signal = Jido.Signal.new!(%{type: hd(types), source: "/cluster/config"}),
         {:ok, _} <- Envelope.new(scope, "config", signal, limits) do
      :ok
    else
      _ -> {:error, :invalid_channel}
    end
  end

  def validate(_, _, _), do: {:error, :invalid_channel}
end
