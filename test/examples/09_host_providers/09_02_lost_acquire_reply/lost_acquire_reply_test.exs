defmodule JidoCluster.Examples.LostAcquireReplyTest do
  use JidoCluster.Test.ClusterCase, tag: :example
  alias Jido.Cluster.Examples.LostAcquireReply
  alias JidoCluster.Examples.Support.HostProviderCase, as: H
  alias JidoCluster.Examples.Support.HostProviderScenario, as: Scenario

  @tag tmp_dir: true, timeout: 90_000
  test "owner and Bedrock restart inspect the original step without another acquire", context do
    Scenario.lost_reply(H.start(context, LostAcquireReply))
  end
end
