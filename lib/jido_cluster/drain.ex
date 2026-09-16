defmodule Jido.Cluster.Drain do
  @moduledoc "Plans a scope-wide drain with complete transition reservation before movement."
  alias Jido.Agent.Ref
  alias Jido.Cluster.Admission
  alias Jido.Cluster.Deployment.Planner
  alias Jido.Topology.Plan

  @doc "Excludes a source and reserves every required arrival, or changes nothing."
  @spec plan(Admission.t(), map(), node(), String.t()) :: {:ok, Admission.t(), [map()]} | {:error, term()}
  def plan(ledger, deployments, source, operation) do
    with true <- Map.has_key?(ledger.hosts, source),
         :ok <- source_certain(ledger, deployments, source) do
      affected =
        deployments
        |> Enum.filter(fn {_, d} -> d.desired == :running and source in Map.values(d.selected) end)
        |> Enum.sort()

      Enum.reduce_while(affected, {:ok, Admission.exclude(ledger, source), []}, fn {id, deployment},
                                                                                   {:ok, next, steps} ->
        append_step(build_step(next, id, deployment, source, operation), steps)
      end)
    else
      false -> {:error, :unknown_host}
      error -> error
    end
  end

  @doc "Maps an exact root placement to the owning core Refs."
  @spec demand(Jido.Topology.Instance.t(), String.t(), map()) :: map()
  def demand(instance, namespace, selected) do
    Map.new(selected, fn {key, host} ->
      agent = Map.fetch!(instance.plan.agents, Plan.resolve(instance.plan, key, :agent))
      {Ref.new!(namespace: namespace, id: agent.id), host}
    end)
  end

  defp build_step(ledger, id, %{phase: :completed} = deployment, source, operation) do
    {namespace, _scope} = ledger.scope
    own = Enum.frequencies(Map.values(deployment.selected))
    hosts = Enum.map(Admission.available_hosts(ledger), &%{&1 | capacity: &1.capacity + Map.get(own, &1.node, 0)})
    step_id = operation <> "/" <> Base.url_encode64(id, padding: false)

    with :ok <- binding_available(deployment),
         {:ok, selected} <-
           Planner.plan(deployment.instance, hosts, [source], deployment.selected, managed_federation: true),
         arrivals = changed(selected, deployment.selected),
         {:ok, ledger} <- Admission.reserve(ledger, id, demand(deployment.instance, namespace, arrivals), step_id) do
      {:ok, ledger,
       %{
         id: id,
         operation_id: step_id,
         selected: selected,
         arrivals: arrivals,
         retired: demand(deployment.instance, namespace, changed(deployment.selected, selected)),
         instance: deployment.instance,
         runner: Map.get(deployment, :runner)
       }}
    end
  end

  defp build_step(_, id, _, _, _), do: {:error, {:deployment_busy, id}}

  defp binding_available(deployment),
    do:
      if(Map.get(deployment, :binding_busy, false), do: {:error, {:deployment_busy, deployment.instance.id}}, else: :ok)

  defp changed(desired, current), do: Map.reject(desired, fn {key, host} -> Map.get(current, key) == host end)
  defp append_step({:ok, ledger, step}, steps), do: {:cont, {:ok, ledger, steps ++ [step]}}
  defp append_step(error, _), do: {:halt, error}

  defp source_certain(ledger, deployments, source) do
    claims = Enum.filter(Admission.claims(ledger), &(&1.host == source))
    uncertain = Enum.filter(claims, &(&1.state == :uncertain))
    busy = Enum.reject(claims, &settled_claim?(&1, deployments))

    cond do
      uncertain != [] -> {:error, {:resources_uncertain, Enum.map(uncertain, & &1.id)}}
      busy != [] -> {:error, {:resources_busy, Enum.map(busy, & &1.id)}}
      true -> :ok
    end
  end

  defp settled_claim?(%{state: :active, topology_id: id}, deployments),
    do: match?(%{phase: :completed, desired: :running}, Map.get(deployments, id))

  defp settled_claim?(_, _), do: false
end
