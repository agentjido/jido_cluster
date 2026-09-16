defmodule JidoCluster.Federation.IntentTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.{Activation, Drain}
  alias Jido.Cluster.Federation.Intent
  alias JidoCluster.Test.Federation.DeclaredTopology

  setup do
    instance = DeclaredTopology.new!(id: "intent")
    activation = Activation.new({"intent-test", Jido.generate_id()}, instance.id)
    selected = %{"listener" => :source}
    {:ok, intent} = Intent.new(instance, selected, activation)
    [ref] = Map.keys(Drain.demand(instance, activation.namespace, selected))
    claim = %{topology_id: instance.id, ref: ref, host: :source, host_incarnation: "source-incarnation", state: :active}
    %{instance: instance, activation: activation, selected: selected, intent: intent, claim: claim}
  end

  test "portable identity survives recovery while revisions and activation change", c do
    assert {:ok, attaching} = Intent.attaching(c.intent, c.instance.id, [c.claim])
    ready = Intent.ready(attaching)
    assert ready["phase"] == "ready"
    assert [%{"path" => ["listener"], "host" => "source", "incarnation" => "source-incarnation"}] = ready["bindings"]
    assert :ok = Intent.validate(ready |> Jason.encode!() |> Jason.decode!(), c.instance, c.selected, c.activation)
    activation = %{c.activation | id: Jido.generate_id(), serial: c.activation.serial + 1}
    d = %{instance: c.instance, selected: c.selected, activation: activation, federation: ready}
    assert {:ok, replacement} = Intent.replacement(d)
    assert replacement["revision"] == 1
    assert replacement["phase"] == "planned"
    assert replacement["activation"] == activation.id
    assert hd(replacement["bindings"])["id"] == hd(ready["bindings"])["id"]
    assert hd(replacement["bindings"])["incarnation"] == nil
    assert Enum.all?(replacement["mirrors"], &(&1["revision"] == 0))

    assert {:error, :binding_revision_limit} =
             Intent.replacement(%{d | federation: %{ready | "revision" => 9_007_199_254_740_991}})
  end

  test "attachment requires exact confirmed host evidence and closed intent remains closed", c do
    assert {:error, :binding_host_unconfirmed} = Intent.attaching(c.intent, c.instance.id, [])

    for change <- [%{host_incarnation: nil}, %{host: :other}, %{state: :uncertain}, %{topology_id: "other"}] do
      assert {:error, :binding_host_unconfirmed} =
               Intent.attaching(c.intent, c.instance.id, [Map.merge(c.claim, change)])
    end

    {:ok, attaching} = Intent.attaching(c.intent, c.instance.id, [c.claim])
    assert {:ok, ^attaching} = Intent.attaching(attaching, c.instance.id, [c.claim])

    assert {:error, :binding_incarnation_changed} =
             Intent.attaching(attaching, c.instance.id, [%{c.claim | host_incarnation: "new"}])

    for intent <- [Intent.detaching(attaching), Intent.stopped(attaching)] do
      assert {:error, :binding_intent_closed} = Intent.attaching(intent, c.instance.id, [c.claim])
    end
  end

  test "stored intent rejects altered logical identity and malformed runtime data", c do
    bad = [
      Map.put(c.intent, "version", 1.0),
      Map.put(c.intent, "revision", -1),
      Map.put(c.intent, "phase", "ready"),
      Map.put(c.intent, "activation", "old"),
      Map.put(c.intent, "bindings", []),
      Map.put(c.intent, "mirrors", []),
      Map.put(c.intent, "pid", self()),
      put_in(c.intent, ["bindings", Access.at(0), "ref"], "other"),
      put_in(c.intent, ["bindings", Access.at(0), "path"], ["other"]),
      put_in(c.intent, ["bindings", Access.at(0), "host"], "other"),
      put_in(c.intent, ["bindings", Access.at(0), "incarnation"], self()),
      update_in(c.intent, ["bindings", Access.at(0)], &Map.delete(&1, "incarnation")),
      put_in(c.intent, ["mirrors", Access.at(0), "revision"], 0.0)
    ]

    for intent <- bad, do: assert({:error, _} = Intent.validate(intent, c.instance, c.selected, c.activation))
  end
end
