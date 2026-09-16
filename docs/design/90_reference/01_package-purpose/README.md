# 01 Package purpose

Status: proposed design. No new runtime contract is accepted here.

The proposed purpose is to coordinate where Jido Agents run across nodes and how their placement changes when capacity or availability changes. Jido core continues to own each Agent and its runtime semantics.

For the newer topology-first API and native placement-provider proposal, read
[02 Top-level API and placement targets](../02_top-level-api/README.md). Its dated
alignment review covers the current coordinator ownership and restart work.

## Read in order

1. [Design](design.md): purpose, owners, operating modes, and proof order.
2. [Alignment](alignment.md): what core V3 and this package implement today.
3. [Questions](questions.md): decisions needed before new APIs.
4. [Lessons](lessons.md): what the first examples add, what core already owns, and stronger acceptance examples.

The first target is a fixed set of connected BEAM nodes. Dynamic infrastructure is a later extension of the same placement model. External workspaces remain a separate design question.

Discussion: [issue #19](https://github.com/agentjido/jido_cluster/issues/19). Return to the [design index](../../README.md).
