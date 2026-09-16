defmodule JidoCluster.Test.DockerHost.Application do
  @moduledoc false
  use Application
  alias JidoCluster.Test.DockerHost.Runtime

  @impl true
  def start(_, _), do: Runtime.start_link(System.get_env())
end
