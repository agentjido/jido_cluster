defmodule Jido.Cluster.Examples.Entities.Device do
  @moduledoc "Stores the count and last accepted event for one device."
  use Jido.Agent, name: "cluster_entity_device"

  agent do
    schema Zoi.object(%{
             count: Zoi.integer() |> Zoi.default(0),
             last_event: Zoi.string() |> Zoi.default("")
           })
  end

  routes do
    signal_source "/examples/entities/device"

    route "examples.entities.device.record" do
      action %{event_id: event_id}, schema: Zoi.object(%{event_id: Zoi.string()}), context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1, last_event: event_id}}
      end

      define :record, args: [:event_id]
    end
  end
end
