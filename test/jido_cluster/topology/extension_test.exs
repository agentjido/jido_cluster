defmodule JidoCluster.Topology.ExtensionTest do
  use ExUnit.Case, async: true
  alias Jido.Cluster.Topology.Extension
  alias Jido.Cluster.Topology.Extension.Worker
  alias Jido.Topology.Codec
  alias JidoCluster.Test.LabelTopology, as: LabelExtension

  defmodule DataTopology do
    @definition %{JidoCluster.Test.TopologyCounter.definition() | module: Jido.Agent, vsn: nil}
    use Jido.Topology, name: "data_cluster_topology", extensions: [Jido.Cluster.Topology.Extension]

    topology do
      agents do
        cluster_worker :worker, definition: @definition, labels: ["compute"]
      end
    end
  end

  test "lowering retains core entries, metadata, and foreign entities without selecting a node" do
    original = %{agents: [%{key: :control, module: String}], metadata: %{purpose: "retained"}}
    worker = %Worker{key: :worker, module: String, labels: ["compute"]}
    foreign = %URI{path: "/foreign"}
    assert {:ok, lowered, [^foreign]} = Extension.lower_topology(original, [worker, foreign])
    assert lowered.agents == original.agents ++ [%{key: :worker, module: String}]
    assert lowered.metadata == %{"jido.cluster.requirements" => %{"worker" => ["compute"]}, purpose: "retained"}
    refute Map.has_key?(List.last(lowered.agents), :node)
    assert {:ok, ^lowered, [^foreign]} = Extension.lower_topology(original, [worker, foreign])
  end

  test "lowering accepts one neutral data-defined Agent" do
    definition = %{JidoCluster.Test.TopologyCounter.definition() | module: Jido.Agent, vsn: nil}

    worker = %Worker{key: :worker, definition: definition, labels: ["compute"]}

    assert {:ok, lowered, []} =
             Extension.lower_topology(%{agents: [], metadata: %{}}, [worker])

    assert [%{key: :worker, definition: ^definition}] = lowered.agents
    assert {:ok, topology} = Jido.Topology.new(Map.put(lowered, :name, "data_cluster_worker"))
    assert [%{definition: ^definition}] = topology.agents
  end

  test "the Cluster DSL accepts a neutral data-defined Agent" do
    definition = %{JidoCluster.Test.TopologyCounter.definition() | module: Jido.Agent, vsn: nil}

    assert [%{key: "worker", definition: ^definition}] = DataTopology.topology().agents
    assert DataTopology.topology().metadata["jido.cluster.requirements"] == %{"worker" => ["compute"]}
  end

  test "invalid labels fail before activation" do
    assert {:error, error} =
             Extension.lower_topology(
               %{agents: [], metadata: %{}},
               [%Worker{key: :worker, module: String, labels: [""]}]
             )

    assert Exception.message(error) =~ "must not be empty"
  end

  test "invalid extension source fails common authoring before startup" do
    module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

    assert_raise CompileError, ~r/Cluster labels must not be empty/, fn ->
      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Jido.Topology, name: "invalid_cluster_labels", extensions: [Extension]

            topology do
              agents do
                cluster_worker :worker, JidoCluster.Test.TopologyCounter, labels: [""]
              end
            end
          end
        end
      )
    end
  end

  test "extended definition stays portable through the core codec" do
    definition = LabelExtension.topology()
    assert definition.metadata["jido.cluster.requirements"] == %{"worker" => ["compute"]}
    assert {:ok, document, registry} = Codec.encode(definition)
    assert {:ok, ^definition} = Codec.decode(document, registry)
  end
end
