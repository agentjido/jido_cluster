defmodule Jido.Cluster.HostProvider do
  @moduledoc """
  Resource lifecycle contract for optional prepared BEAM host providers.

  The scope service records a stable step before acquisition. An indeterminate
  result requires inspection of that same step. It never permits acquisition
  under a new identity. Provider options contain runtime configuration and must
  not enter the step, resource record, Agent state, or journal.

  A resource observation does not grant placement authority. Core compatibility,
  HostRuntime registration, and shared admission still precede Agent activation.
  Ownership comes from recorded scope intent, never from discovered labels alone.
  An owned prepared runtime starts `HostRuntime` with `provider_step:` set to
  `Step.to_record(step)`. A compatible connected node without that exact boot
  identity cannot open provider admission. The adapter must ensure that this
  runtime belongs to the resource returned for the step. This is a trusted
  deployment contract, not authentication against malicious BEAM peers.

  Release addresses an exact resource ID and incarnation. A successful release
  return means that the provider accepted the request; the caller must inspect
  the original step before it records deletion. An absent observation cannot
  settle a never-observed acquisition whose external result remains unknown.

  Adapters must bound calls and returned observations. They must distinguish an
  authoritative absent result from an unavailable provider. Optional discovery
  returns at most the requested limit and cannot authorize deletion by itself.
  """

  alias Jido.Cluster.HostProvider.{Resource, Step}

  @type failure :: {:rejected, term()} | {:indeterminate, term()}
  @type observation :: {:ok, Resource.t() | :absent} | {:error, term()}

  @callback validate_options(keyword()) :: :ok | {:error, term()}
  @callback acquire(Step.t(), keyword()) :: {:ok, Resource.t()} | {:error, failure()}
  @callback inspect(Step.t(), keyword()) :: observation()
  @callback release(Resource.t(), keyword()) :: :ok | {:error, failure()}
  @callback discover({String.t(), String.t()}, pos_integer(), keyword()) ::
              {:ok, [Resource.t()]} | {:error, term()}
  @optional_callbacks discover: 3
end
