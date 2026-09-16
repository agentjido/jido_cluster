defmodule Jido.Cluster.HostProvider.Release do
  @moduledoc """
  Pure release decision after journaled host exclusion and cleanup inspection.

  This function makes no provider call and does not grant scope authority. The
  service must first confirm release intent, exclude new claims, and gather the
  current complete claim set plus Agent and binding cleanup receipts. It must
  record an adopted resource before evaluating release again.

  Missing resources after unknown acquisition remain uncertain. Once an exact
  resource has been recorded, authoritative absence can confirm its release.
  Borrowed resources and resources with different ownership coordinates remain
  untouched, even when names or host addresses are reused.
  """
  alias Jido.Cluster.HostProvider.{Resource, Step}

  @type decision :: :released | {:adopt, Resource.t()} | {:release, Resource.t()} | {:keep, atom()}

  @doc "Selects a release action from recorded ownership and current evidence."
  @spec decide(map(), Jido.Cluster.HostProvider.observation(), map()) :: decision()
  def decide(%{ownership: :borrowed}, _, _), do: {:keep, :borrowed}
  def decide(%{desired: :running}, _, _), do: {:keep, :running_intent}

  def decide(%{ownership: :owned, desired: :released, step: %Step{} = step, resource: resource}, observation, evidence) do
    if evidence == %{claims: [], agents: :settled, bindings: :settled, admission: :closed},
      do: observed(step, resource, observation),
      else: {:keep, :cleanup_unconfirmed}
  end

  def decide(_, _, _), do: {:keep, :invalid_session}

  defp observed(_step, _resource, {:error, _}), do: {:keep, :inspection_unavailable}
  defp observed(_step, nil, {:ok, :absent}), do: {:keep, :acquisition_unresolved}
  defp observed(step, %Resource{step: step}, {:ok, :absent}), do: :released
  defp observed(step, nil, {:ok, %Resource{step: step} = current}), do: {:adopt, current}

  defp observed(step, %Resource{step: step} = recorded, {:ok, %Resource{} = current}) do
    if Resource.same?(recorded, current),
      do: {:release, current},
      else: {:keep, :resource_identity_changed}
  end

  defp observed(_, _, _), do: {:keep, :resource_identity_changed}
end
