# Jido Cluster V3 guides

These guides describe the current `v3-spike` runtime. The package is an alpha
local integration build. Start with a named deployment, then read the guide
for the capability that your application needs.

| Guide | Use it for |
| --- | --- |
| [Named deployments](named-deployments.md) | Define a scope, admit a Topology, route by Ref, and stop it |
| [Journal and recovery](recovery.md) | Select storage, read uncertain results, and recover saved intent |
| [Federated Signals](federated-signals.md) | Declare a channel and publish to its ready subscribers |
| [Host providers](host-providers.md) | Acquire, check, and release an optional prepared host |
| [Entities](entities.md) | Admit bounded demand by a domain key and preserve identity across moves |

Use the [example catalog](../examples/README.md) to run each contract with
real Agents and local peers. Use the [testing guide](testing.md) for test
selection. Named Cluster scopes share admission and recovery across declared
Topologies and entity workloads.
