# 11 System examples

These examples combine the earlier deployment, admission, journal, and federation
contracts. Read the focused examples first to understand each failure boundary.

1. [11_01 Deployment lifecycle](11_01_deployment_lifecycle/README.md): recover a
   partial drain, retain uncertain claims, permit independent work, and check
   cleanup with managed and attached Core instances.

2. [11_02 Provider lifecycle](11_02_provider_lifecycle/README.md): run the same
   lifecycle with acquired and borrowed resources, then verify owned cleanup and
   borrowed retention in a controlled provider.

The provider example has a credential-free controlled backend. Its explicit
Docker runners pass in both managed and attached Core modes on the local
Engine. Read the [S6 acceptance record](../../docs/design/06_host-providers/plan.md#real-docker-acceptance-and-s6-audit)
for the image, commands, cleanup result, and limits. No remote CI result exists
for this unpushed worktree.
