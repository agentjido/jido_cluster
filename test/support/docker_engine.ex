defmodule JidoCluster.Test.DockerEngine do
  @moduledoc false
  import ExUnit.Assertions
  import JidoCluster.Test.ClusterCase
  import JidoCluster.Test.Eventually
  alias Jido.Cluster.HostProvider.Docker
  alias Jido.Cluster.HostProvider.Docker.{HTTP, Options}
  alias Jido.Cluster.HostProvider.Step
  alias Jido.Cluster.HostRuntime
  alias JidoCluster.Test.DockerHost.Runtime

  def preflight! do
    socket = required!("JIDO_CLUSTER_DOCKER_SOCKET")
    image = required!("JIDO_CLUSTER_DOCKER_IMAGE")
    options = [endpoint: {:unix, socket}, engine_id: "preflight", container: %{"Image" => image}, timeout: 5_000]

    with {:ok, config} <- Options.new(options),
         {:ok, 200, %{"ID" => engine}} <- HTTP.request(config, :get, "/info"),
         {:ok, 200, %{"Id" => image_id}} <-
           HTTP.request(config, :get, "/images/" <> URI.encode_www_form(image) <> "/json") do
      # Pin the local prepared image ID so a moved tag cannot change this run.
      options |> Keyword.put(:engine_id, engine) |> Keyword.put(:container, %{"Image" => image_id})
    else
      _ ->
        raise "Docker acceptance requires a responding Engine and a local prepared image; no test resource was created"
    end
  end

  def start(c, options, extra_env \\ [], cleanup? \\ true) do
    [control] = c.cluster.nodes
    namespace = "docker-acceptance/#{Jido.generate_id()}"
    name = :peer.random_name(~c"jido_docker_worker") |> List.to_string()
    worker = String.to_atom(name <> "@127.0.0.1")
    cookie = cluster_call(c.cluster, control, Node, :get_cookie, [])
    table = shared_table(c.cluster, [control])
    persistence = {Jido.Persistence.Mnesia, table: table}

    {:ok, core} =
      cluster_call(c.cluster, control, DynamicSupervisor, :start_child, [
        JidoCluster.Test.Supervisor,
        {Jido, name: Runtime.core(), namespace: namespace, persistence: persistence}
      ])

    {:ok, step} =
      Step.new(%{
        namespace: namespace,
        scope: "default",
        host: Atom.to_string(worker),
        provider: "docker",
        id: Jido.generate_id()
      })

    env =
      [
        "JIDO_CLUSTER_CONTROL_NODE=" <> Atom.to_string(control),
        "JIDO_CLUSTER_COOKIE=" <> Atom.to_string(cookie),
        "JIDO_CLUSTER_TABLE=" <> Atom.to_string(table)
      ] ++ extra_env

    container = options[:container] |> Map.put("Env", env) |> Map.put("HostConfig", %{"NetworkMode" => "host"})
    options = Keyword.put(options, :container, container)

    # Register before acquisition. Inspect exact step labels and immutable IDs
    # on failure too. Never remove resources from another test namespace.
    if cleanup?, do: ExUnit.Callbacks.on_exit(fn -> cleanup(step, options) end)
    Map.merge(c, %{control: control, worker: worker, namespace: namespace, step: step, options: options, core: core})
  end

  def acquire(c) do
    assert {:ok, resource} = Docker.acquire(c.step, c.options)
    resource
  end

  def ready(c) do
    expected = [namespace: c.namespace, provider_step: Step.to_record(c.step)]

    eventually(
      fn ->
        match?({:ok, _}, remote(c, HostRuntime, :probe, [HostRuntime.name(Runtime.core()), expected]))
      end,
      timeout: 15_000
    )

    assert {:ok, info} = remote(c, HostRuntime, :probe, [HostRuntime.name(Runtime.core()), expected])
    assert info.persistence_identity == {:adapter, Jido.Persistence.Mnesia}
    assert c.worker in cluster_call(c.cluster, c.control, Node, :list, [])
    assert c.control in remote(c, Node, :list, [])
    info
  end

  def remote(c, module, function, args) do
    cluster_call(c.cluster, c.control, :erpc, :call, [c.worker, module, function, args, 2_000], 3_000)
  catch
    _, _ -> {:error, :docker_worker_unavailable}
  end

  def remove(c, resource) do
    assert :ok = Docker.release(resource, c.options)
    finish(c)
  end

  def finish(c) do
    eventually(fn -> Docker.inspect(c.step, c.options) == {:ok, :absent} end, timeout: 15_000)
    assert {:ok, []} = Docker.discover({c.namespace, "default"}, 4, c.options)
    eventually(fn -> c.worker not in cluster_call(c.cluster, c.control, Node, :list, []) end)

    assert :ok =
             cluster_call(c.cluster, c.control, DynamicSupervisor, :terminate_child, [
               JidoCluster.Test.Supervisor,
               c.core
             ])

    refute cluster_call(c.cluster, c.control, Process, :alive?, [c.core])
  end

  def cleanup(step, options) do
    assert {:ok, resources} = Docker.discover({step.namespace, step.scope}, 4, options)

    for resource <- resources do
      assert resource.step == step
      assert :ok = Docker.release(resource, options)
    end

    eventually(fn -> Docker.discover({step.namespace, step.scope}, 4, options) == {:ok, []} end, timeout: 15_000)
  end

  defp required!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "Docker acceptance requires #{name}; see test/fixtures/docker_host/README.md"
    end
  end
end
