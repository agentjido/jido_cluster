defmodule JidoCluster.Examples.AdmissionTest do
  use JidoCluster.Examples.Support.PlacementCase
  alias Jido.Cluster.Examples.CapacityAdmission

  test "insufficient capacity starts no workers, then an inventory update admits the complete topology", c do
    [first, second] = c.cluster.nodes
    scheduler = start_scheduler(c, CapacityAdmission, [host(first, [], 1)])
    eventually(fn -> scheduler_call(c, scheduler, :status).status == :blocked end)
    status = scheduler_call(c, scheduler, :status)
    assert status.error == {:no_capacity, "first"}
    assert status.reservations == %{}
    assert scheduler_call(c, scheduler, :whereis_agent, [:first]) == nil
    assert scheduler_call(c, scheduler, :whereis_agent, [:second]) == nil
    assert :ok = scheduler_call(c, scheduler, :update_hosts, [[host(first), host(second)]])
    status = ready(c, scheduler)
    assert status.reservations == %{first => 1, second => 1}
    workers = for key <- [:first, :second], do: scheduler_call(c, scheduler, :whereis_agent, [key])
    assert workers |> Enum.map(&node/1) |> Enum.sort() == c.cluster.nodes
    stop_scheduler(c, scheduler)
    for worker <- workers, do: refute(cluster_call(c.cluster, node(worker), Process, :alive?, [worker]))
  end
end
