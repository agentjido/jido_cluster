defmodule JidoCluster.Test.IncrementAction do
  use Jido.Action,
    name: "increment",
    description: "Increment a counter",
    schema: []

  @impl true
  def run(_params, context) do
    count = context.state |> Map.get(:count, 0)
    {:ok, %{count: count + 1}}
  end
end

defmodule JidoCluster.Test.CounterAgent do
  use Jido.Agent,
    name: "jido_cluster_counter",
    schema: [
      count: [type: :integer, default: 0]
    ],
    signal_routes: [
      {"inc", JidoCluster.Test.IncrementAction}
    ]
end
