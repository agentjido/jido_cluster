defmodule JidoCluster.Examples.AdmissionTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.CapacityAdmission

  test "insufficient capacity starts no workers, then an inventory update admits the complete topology", c do
    [first, second] = c.cluster.nodes

    # This host has one slot but no compute label. Neither declared worker is
    # eligible, so admission must fail with no partial topology running.
    scheduler = start_scheduler(c, CapacityAdmission, [host(first, [], 1)])
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :blocked end)
    status = scheduler_call(c, scheduler, :status)
    assert status.error == {:no_capacity, "first"}
    assert status.reservations == %{}
    assert scheduler_call(c, scheduler, :whereis_agent, [:first]) == nil
    assert scheduler_call(c, scheduler, :whereis_agent, [:second]) == nil

    # Inventory updates are public Scheduler requests. Add two eligible hosts
    # with one slot each, enough for the complete two-worker topology.
    assert :ok = scheduler_call(c, scheduler, :update_hosts, [[host(first), host(second)]])
    status = ready(c, scheduler)
    assert status.reservations == %{first => 1, second => 1}

    # Slot accounting must agree with actual worker locations. These budgets
    # apply to this Scheduler; they are not global reservations for each host.
    workers = for key <- [:first, :second], do: scheduler_call(c, scheduler, :whereis_agent, [key])
    assert workers |> Enum.map(&node/1) |> Enum.sort() == c.cluster.nodes

    # Both admitted workers are owned resources and must stop during cleanup.
    stop_scheduler(c, scheduler)
    for worker <- workers, do: refute(cluster_call(c.cluster, node(worker), Process, :alive?, [worker]))
  end
end
