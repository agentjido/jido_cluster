defmodule JidoCluster.AdmissionTest do
  use ExUnit.Case, async: true
  alias Jido.Agent.Ref
  alias Jido.Cluster.Admission

  defp host(node, capacity), do: %{node: node, capacity: capacity, labels: [], available: true}
  defp ref(id), do: Ref.new!(namespace: "ledger", id: id)

  test "pool aliases share one inventory and conflicting budgets are rejected" do
    assert {:ok, ledger} = Admission.new({"ledger", "scope"}, [host(:a, 1), host(:a, 1)])
    assert [%{capacity: 1}] = Admission.available_hosts(ledger)

    assert {:ok, ^ledger} =
             Admission.new({"ledger", "scope"}, [host(:a, 1), Map.put(host(:a, 1), :allocation, "default")])

    assert {:error, :conflicting_host_budget} =
             Admission.new({"ledger", "scope"}, [Map.put(host(:a, 1), :allocation, 12)])

    assert {:error, :conflicting_host_budget} = Admission.new({"ledger", "scope"}, [host(:a, 1), host(:a, 2)])
  end

  test "complete reservation rejects demand without changing the ledger" do
    {:ok, ledger} = Admission.new({"ledger", "scope"}, [host(:a, 1)])
    demands = %{ref("first") => :a, ref("second") => :a}
    assert {:error, {:no_capacity, :a}} = Admission.reserve(ledger, "work", demands, "operation")
    assert Admission.claims(ledger) == []
  end

  test "repeated reserve and confirmed release are idempotent" do
    {:ok, empty} = Admission.new({"ledger", "scope"}, [host(:a, 1)])
    demand = %{ref("agent") => :a}
    assert {:ok, ledger} = Admission.reserve(empty, "work", demand, "operation")
    assert {:ok, ^ledger} = Admission.reserve(ledger, "work", demand, "operation")
    assert {:error, :operation_conflict} = Admission.reserve(ledger, "other", demand, "operation")
    assert {:error, :unconfirmed_cleanup} = Admission.release(ledger, "work", :timeout)
    assert {:ok, released} = Admission.release(ledger, "work", :confirmed)
    assert {:ok, ^released} = Admission.release(released, "work", :confirmed)
    assert Admission.claims(released) == []
  end

  test "uncertainty retains slots and permits only independent capacity" do
    {:ok, ledger} = Admission.new({"ledger", "scope"}, [host(:a, 2), host(:b, 1)])
    {:ok, ledger} = Admission.reserve(ledger, "parked", %{ref("parked") => :a}, "first")
    ledger = Admission.mark(ledger, "first", :uncertain)
    assert [%{state: :uncertain}] = Admission.claims(ledger)
    assert {:error, {:resources_uncertain, _}} = Admission.reserve(ledger, "same", %{ref("same") => :a}, "second")
    assert {:ok, independent} = Admission.reserve(ledger, "other", %{ref("other") => :b}, "third")
    assert length(Admission.claims(independent)) == 2
    assert {:error, {:resources_uncertain, _}} = Admission.reserve(ledger, "parked", %{ref("parked") => :b}, "fourth")
  end

  test "movement holds source and target claims until confirmed retirement" do
    {:ok, ledger} = Admission.new({"ledger", "scope"}, [host(:a, 1), host(:b, 1)])
    {:ok, ledger} = Admission.reserve(ledger, "work", %{ref("agent") => :a}, "deploy")
    ledger = Admission.mark(ledger, "deploy", :active)
    {:ok, ledger} = Admission.reserve(ledger, "work", %{ref("agent") => :b}, "move")
    assert length(Admission.claims(ledger)) == 2
    {:ok, ledger} = Admission.retire(ledger, "work", %{ref("agent") => :a}, :confirmed)
    assert [%{host: :b}] = Admission.claims(ledger)
    ledger = Admission.exclude(ledger, :a)
    assert {:error, {:host_excluded, :a}} = Admission.reserve(ledger, "fresh", %{ref("fresh") => :a}, "fresh")
  end

  test "generated reservation and retirement sequences conserve slots" do
    {:ok, initial} = Admission.new({"ledger", "scope"}, [host(:a, 3), host(:b, 2)])
    # The independent model is just the set of admitted deployment IDs. It has
    # no implementation claim transitions or ledger helper calls.
    :rand.seed(:exsss, {41, 72, 93})

    Enum.reduce(1..250, {initial, %{}}, fn step, {ledger, model} ->
      id = Integer.to_string(:rand.uniform(12))
      node = if rem(String.to_integer(id), 2) == 0, do: :a, else: :b

      if :rand.uniform(2) == 1 and not Map.has_key?(model, id) do
        expected = Enum.count(model, fn {_, value} -> value == node end) < if(node == :a, do: 3, else: 2)

        case Admission.reserve(ledger, id, %{ref(id) => node}, "op-#{step}") do
          {:ok, next} ->
            assert expected
            assert length(Admission.claims(next)) == map_size(model) + 1
            {next, Map.put(model, id, node)}

          {:error, {:no_capacity, ^node}} ->
            refute expected
            {ledger, model}
        end
      else
        {:ok, next} = Admission.release(ledger, id, :confirmed)
        model = Map.delete(model, id)
        assert length(Admission.claims(next)) == map_size(model)
        {next, model}
      end
    end)
  end
end
