defmodule JidoCluster.Distributed.PeerSmokeTest do
  use ExUnit.Case, async: false

  import JidoCluster.Test.Eventually

  test "raw :peer nodes can connect and execute cluster modules" do
    cookie = "peer_cookie_#{System.unique_integer([:positive])}"
    unique = System.unique_integer([:positive])

    {:ok, p1, n1} =
      :peer.start_link(%{
        name: :"jc_peer_a_#{unique}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", String.to_charlist(cookie)]
      })

    on_exit(fn ->
      try do
        :peer.stop(p1)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, p2, n2} =
      :peer.start_link(%{
        name: :"jc_peer_b_#{unique}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"-setcookie", String.to_charlist(cookie)]
      })

    on_exit(fn ->
      try do
        :peer.stop(p2)
      catch
        _, _ -> :ok
      end
    end)

    :ok = :peer.call(p1, :code, :add_paths, [:code.get_path()])
    :ok = :peer.call(p2, :code, :add_paths, [:code.get_path()])

    assert true = :peer.call(p1, Node, :connect, [n2])

    eventually(fn ->
      nodes = :peer.call(p1, Node, :list, [])
      n2 in nodes
    end)

    connected = :peer.call(p1, JidoCluster.Topology, :connected_nodes, [])

    assert n1 in connected
    assert n2 in connected
  end
end
