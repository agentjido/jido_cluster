defmodule JidoCluster.HostProviderTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.HostProvider.{Release, Resource, Step}
  alias JidoCluster.Test.HostProvider

  setup do
    server = start_supervised!(HostProvider)

    {:ok, step} =
      Step.new(%{namespace: "provider-test", scope: "default", host: "worker", provider: "fake", id: "step-1"})

    %{server: server, opts: [server: server], step: step}
  end

  test "step and resource records round trip without runtime options", c do
    {:ok, resource} = HostProvider.acquire(c.step, c.opts)
    {:ok, record} = resource |> Resource.to_record() |> Jason.encode!() |> Jason.decode()
    assert {:ok, ^resource} = Resource.from_record(record)
    assert {:error, :invalid_host_resource} = Resource.from_record(Map.put(record, "secret", "invalid-extra-field"))
    assert {:error, :invalid_host_resource} = Resource.from_record(%{record | "state" => "unknown"})
    assert {:error, :invalid_host_step} = Step.from_record(Map.put(record["step"], "opts", %{}))

    for value <- [nil, "", :atom, self(), <<255>>, String.duplicate("x", 257)] do
      assert {:error, :invalid_host_step} = Step.new(%{Map.from_struct(c.step) | id: value})
    end
  end

  test "a lost acquire reply is inspected by the original step without another resource", c do
    :ok = HostProvider.mode(c.server, :lose_acquire_reply)
    assert {:error, {:indeterminate, :timeout}} = HostProvider.acquire(c.step, c.opts)
    assert [resource] = HostProvider.resources(c.server)
    assert {:ok, ^resource} = HostProvider.inspect(c.step, c.opts)
    assert {:ok, ^resource} = HostProvider.acquire(c.step, c.opts)
    assert [^resource] = HostProvider.resources(c.server)
    assert :ok = HostProvider.release(resource, c.opts)
    assert {:ok, :absent} = HostProvider.inspect(c.step, c.opts)
    assert [] = HostProvider.resources(c.server)
    assert {:error, {:rejected, :step_closed}} = HostProvider.acquire(c.step, c.opts)
  end

  test "a lost release reply is settled only by inspection", c do
    {:ok, resource} = HostProvider.acquire(c.step, c.opts)
    :ok = HostProvider.mode(c.server, :lose_release_reply)
    assert {:error, {:indeterminate, :timeout}} = HostProvider.release(resource, c.opts)
    session = session(c.step, resource)
    assert {:keep, :inspection_unavailable} = Release.decide(session, {:error, :timeout}, settled())
    observation = HostProvider.inspect(c.step, c.opts)
    assert observation == {:ok, :absent}
    assert :released = Release.decide(session, observation, settled())
  end

  test "unknown acquisition absence stays unresolved and discovery requires adoption", c do
    session = session(c.step, nil)
    assert {:keep, :acquisition_unresolved} = Release.decide(session, HostProvider.inspect(c.step, c.opts), settled())
    {:ok, resource} = HostProvider.acquire(c.step, c.opts)
    assert {:adopt, ^resource} = Release.decide(session, {:ok, resource}, settled())
    assert {:release, ^resource} = Release.decide(%{session | resource: resource}, {:ok, resource}, settled())
    assert :ok = HostProvider.release(resource, c.opts)
  end

  test "inspection outage is different from absence and discovery is bounded", c do
    {:ok, first} = HostProvider.acquire(c.step, c.opts)
    {:ok, second} = HostProvider.acquire(%{c.step | id: "step-2"}, c.opts)
    :ok = HostProvider.mode(c.server, :inspect_unavailable)
    assert {:error, :unavailable} = HostProvider.inspect(c.step, c.opts)
    assert {:error, :discovery_limit} = HostProvider.discover({c.step.namespace, c.step.scope}, 1, c.opts)
    assert {:ok, [^first, ^second]} = HostProvider.discover({c.step.namespace, c.step.scope}, 2, c.opts)
    assert {:ok, []} = HostProvider.discover({c.step.namespace, "another"}, 2, c.opts)
    for resource <- [first, second], do: assert(:ok = HostProvider.release(resource, c.opts))
  end

  test "a stale release cannot destroy the inspected current incarnation", c do
    {:ok, current} = HostProvider.acquire(c.step, c.opts)
    stale = %{current | incarnation: "old"}
    assert {:error, {:rejected, :stale_resource}} = HostProvider.release(stale, c.opts)
    assert {:ok, ^current} = HostProvider.inspect(c.step, c.opts)
    assert {:keep, :resource_identity_changed} = Release.decide(session(c.step, stale), {:ok, current}, settled())
    assert :ok = HostProvider.release(current, c.opts)
  end

  test "release model excludes every incomplete cleanup and preservation control", c do
    {:ok, resource} = HostProvider.acquire(c.step, c.opts)

    for ownership <- [:owned, :borrowed],
        desired <- [:running, :released],
        claims <- [[], [%{id: "retained"}], :unknown],
        agents <- [:settled, :uncertain],
        bindings <- [:settled, :uncertain],
        admission <- [:closed, :open] do
      session = %{session(c.step, resource) | ownership: ownership, desired: desired}
      evidence = %{claims: claims, agents: agents, bindings: bindings, admission: admission}
      result = Release.decide(session, {:ok, resource}, evidence)

      allowed = ownership == :owned and desired == :released and evidence == settled()
      assert match?({:release, ^resource}, result) == allowed
      assert match?({:keep, _}, result) == not allowed
    end

    assert [{:acquire, _}] = HostProvider.calls(c.server)
    assert [^resource] = HostProvider.resources(c.server)
    assert :ok = HostProvider.release(resource, c.opts)
  end

  defp session(step, resource), do: %{step: step, resource: resource, desired: :released, ownership: :owned}
  defp settled, do: %{claims: [], agents: :settled, bindings: :settled, admission: :closed}
end
