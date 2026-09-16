defmodule Jido.Cluster.Examples.JournalRecovery.Worker do
  @moduledoc "Records committed work while the Cluster coordinator restarts."
  use Jido.Agent, name: "journal_recovery_worker"

  agent do
    schema Zoi.object(%{count: Zoi.integer() |> Zoi.default(0)})
  end

  routes do
    signal_source "/examples/journal_recovery/worker"

    route "examples.journal_recovery.worker.work" do
      action _input, context: context do
        {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
      end

      define :work
    end
  end
end
