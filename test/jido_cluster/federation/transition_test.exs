defmodule JidoCluster.Federation.TransitionTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.{Activation, Drain}
  alias Jido.Cluster.Federation.{Intent, Transition}
  alias JidoCluster.Test.Federation.DeclaredTopology

  setup do
    instance = DeclaredTopology.new!(id: "transition")
    activation = Activation.new({"transition-test", Jido.generate_id()}, instance.id)
    selected = %{"listener" => :source}
    {:ok, intent} = Intent.new(instance, selected, activation)
    [ref] = Map.keys(Drain.demand(instance, activation.namespace, selected))
    claim = %{topology_id: instance.id, ref: ref, host: :source, host_incarnation: "source-incarnation", state: :active}
    {:ok, intent} = Intent.attaching(intent, instance.id, [claim])
    intent = Intent.ready(intent)
    d = %{instance: instance, selected: selected, activation: activation, federation: intent}
    %{d: d, hosts: ["source", "target", activation.node], claim: claim}
  end

  test "transition retains exact source evidence and prepares bounded successor revisions", c do
    {:ok, desired, transition} = Transition.new(c.d, %{"listener" => :target}, c.d.federation["mirrors"])
    d = %{c.d | selected: %{"listener" => :target}, federation: desired}
    assert desired["revision"] == 1
    assert transition["previous"] == c.d.federation
    assert transition["phase"] == "retiring"
    assert hd(desired["bindings"])["id"] == hd(c.d.federation["bindings"])["id"]
    assert resource(desired, "target")["revision"] == 0
    assert resource(desired, c.d.activation.node)["revision"] == 1
    assert :ok = Transition.validate(Jason.decode!(Jason.encode!(transition)), d, c.d.selected, c.hosts)
    assert :ok = Transition.validate(%{transition | "phase" => "retired"}, d, c.d.selected, c.hosts)

    {:ok, attached} =
      Intent.attaching(desired, d.instance.id, [%{c.claim | host: :target, host_incarnation: "target-incarnation"}])

    d = %{d | federation: Intent.ready(attached)}
    history = [resource(c.d.federation, "source") | desired["mirrors"]]
    {:ok, returned, next} = Transition.new(d, c.d.selected, history)
    assert returned["revision"] == 2
    assert resource(returned, "source")["revision"] == 1
    assert resource(returned, c.d.activation.node)["revision"] == 2
    assert :ok = Transition.validate(next, %{d | selected: c.d.selected, federation: returned}, d.selected, c.hosts)
  end

  test "missing cleanup identities and altered retirement records fail closed", c do
    assert {:error, :binding_transition_conflict} = Transition.new(c.d, %{"listener" => :target}, [])
    {:ok, desired, transition} = Transition.new(c.d, %{"listener" => :target}, c.d.federation["mirrors"])
    d = %{c.d | selected: %{"listener" => :target}, federation: desired}

    bad = [
      %{transition | "phase" => "ready"},
      %{transition | "retire" => []},
      %{transition | "retire" => transition["retire"] ++ transition["retire"]},
      %{transition | "from" => %{"listener" => "target"}},
      put_in(transition, ["previous", "revision"], 4),
      put_in(transition, ["retire", Access.at(0), "revision"], 9_007_199_254_740_992),
      put_in(transition, ["retire", Access.at(0), "host"], "unknown"),
      put_in(transition, ["retire", Access.at(0), "pid"], self())
    ]

    for record <- bad,
        do: assert({:error, :invalid_binding_transition} = Transition.validate(record, d, c.d.selected, c.hosts))

    changed = put_in(d, [:federation, "mirrors", Access.at(0), "revision"], 12)
    assert {:error, :invalid_binding_transition} = Transition.validate(transition, changed, c.d.selected, c.hosts)
  end

  defp resource(intent, host), do: Enum.find(intent["mirrors"], &(&1["host"] == host))
end
