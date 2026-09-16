defmodule Jido.Cluster.Federation.Transport do
  @moduledoc """
  Bounded submission boundary for an explicitly selected federation transport.

  A handle identifies one established destination. Implementations must reject
  excess submissions before placing payloads in their process mailboxes. An
  uncertain result must not reopen a credit that could still carry a payload.
  `transmit/2` is an internal transport observation, not a business receipt or an
  acknowledgement that a subscribing Agent consumed the Signal.
  """
  alias Jido.Cluster.Federation.Envelope

  @callback transmit(term(), Envelope.t()) :: {:ok, :appended | :duplicate} | {:error, term()}
end
