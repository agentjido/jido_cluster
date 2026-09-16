defmodule Jido.Cluster.Federation.Connections do
  @moduledoc """
  Builds a fixed, bounded set of owned connected-BEAM sender handles.

  One sender is created per interested remote host. A failed setup stays in the
  target set with a closed handle, so publications report that host's rejection
  instead of silently removing its interest. Repeated configuration reuses the
  same result; it does not consume another receiver credit. Generation replacement
  belongs to lifecycle reconciliation. This module adds no payload mailbox.
  """
  @behaviour Jido.Cluster.Federation.Transport

  alias Jido.Cluster.Federation.{Channel, Envelope, Limits}
  alias Jido.Cluster.Federation.Transport.Connected

  @doc "Checks that every destination is a known remote host in this exact channel."
  @spec validate([map()], map()) :: :ok | {:error, :invalid_destinations}
  def validate(destinations, config) when is_list(destinations) do
    if length(destinations) < config.limits.max_hosts and
         Enum.all?(destinations, &valid_destination?(&1, config)) and
         length(destinations) == length(Enum.uniq_by(destinations, & &1.host)),
       do: :ok,
       else: {:error, :invalid_destinations}
  end

  def validate(_, _), do: {:error, :invalid_destinations}

  @doc "Makes one supervised connection attempt and retains a bounded result."
  @spec open(map(), pid()) :: map()
  def open(destination, supervisor) do
    result = start_sender(destination.receiver, supervisor)
    Map.merge(destination, result)
  end

  @doc "Produces bridge targets, including closed handles for failed setup attempts."
  @spec targets([map()]) :: [map()]
  def targets(connections),
    do: Enum.map(connections, &%{host: &1.host, transport: __MODULE__, handle: Map.take(&1, [:endpoint])})

  @doc "Uses the sender's admission gate or rejects a known closed connection."
  @impl true
  @spec transmit(map(), Envelope.t()) :: {:ok, :appended | :duplicate} | {:error, term()}
  def transmit(%{endpoint: nil}, _envelope), do: {:error, :closed}
  def transmit(%{endpoint: endpoint}, envelope), do: Connected.transmit(endpoint, envelope)

  @doc "Reports current connection health without changing the configured target set."
  @spec status(map()) :: map()
  def status(%{endpoint: nil} = connection),
    do: %{host: connection.host, health: :degraded, reason: connection.reason}

  def status(connection) do
    status = Connected.status(connection.pid)
    Map.merge(status, %{host: connection.host, reason: connection.reason})
  catch
    :exit, _ -> %{host: connection.host, health: :degraded, reason: :sender_unavailable}
  end

  defp start_sender(receiver, supervisor) do
    case DynamicSupervisor.start_child(supervisor, {Connected, receiver: receiver}) do
      {:ok, pid} -> sender_endpoint(pid)
      {:error, reason} -> %{pid: nil, endpoint: nil, reason: setup_reason(reason)}
    end
  catch
    :exit, _ -> %{pid: nil, endpoint: nil, reason: :setup_uncertain}
  end

  defp sender_endpoint(pid) do
    %{pid: pid, endpoint: Connected.endpoint(pid), reason: nil}
  catch
    :exit, _ -> %{pid: pid, endpoint: nil, reason: :setup_uncertain}
  end

  defp setup_reason(reason) when reason in [:capacity, :host_not_allowed, :invalid_receiver], do: reason
  defp setup_reason(_), do: :connection_unavailable

  defp valid_destination?(%{host: host, receiver: receiver} = destination, config) when map_size(destination) == 2 do
    host != node() and host in config.allowed_nodes and valid_receiver?(receiver, host, config)
  end

  defp valid_destination?(_, _), do: false

  defp valid_receiver?(
         %{pid: pid, scope: scope, types: types, limits: %Limits{} = limits, generation: generation} = receiver,
         host,
         config
       )
       when map_size(receiver) == 5 do
    is_pid(pid) and node(pid) == host and scope == config.scope and types == config.types and
      is_binary(generation) and byte_size(generation) in 1..128 and
      Channel.validate(scope, types, limits) == :ok
  end

  defp valid_receiver?(_, _, _), do: false
end
