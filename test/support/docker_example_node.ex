defmodule JidoCluster.Test.DockerExampleNode do
  @moduledoc false
  alias Jido.Cluster.HostProvider.Docker
  alias JidoCluster.Test.{ClusterCase, DockerExampleProvider, DockerExec}

  def step(entry) do
    steps = ClusterCase.cluster_call(entry.cluster, entry.control, DockerExampleProvider, :steps, [entry.provider])
    Enum.find(steps, &(&1.host == Atom.to_string(entry.worker)))
  end

  def observe(entry) do
    case step(entry) do
      nil -> {:error, :step_not_recorded}
      step -> Docker.inspect(step, entry.docker)
    end
  end

  def request(entry, module, function, args, timeout) do
    case observe(entry) do
      {:ok, resource} when is_struct(resource) ->
        DockerExec.call(resource, entry.docker, module, function, args, timeout)

      _ ->
        {:error, :docker_worker_unavailable}
    end
  end

  def call(entry, module, function, args, timeout) do
    case request(entry, module, function, args, timeout) do
      {:ok, result} -> result
      _ -> raise "Independent Docker worker call failed; no worker result is established"
    end
  end
end
