# Jido Cluster design

This folder defines the proposed purpose of `jido_cluster`. It separates the current implementation from proposed contracts and unresolved questions.

Start with [01 Package purpose](01_package-purpose/README.md). Read the [design](01_package-purpose/design.md), then the [alignment review](01_package-purpose/alignment.md), then the [decision questions](01_package-purpose/questions.md).

## Design source

The main discussion is [issue #19: Distributed Agent systems and dynamic infrastructure](https://github.com/agentjido/jido_cluster/issues/19). It is an idea set, not an accepted API or release plan. [Issue #1: Common usage scenarios](https://github.com/agentjido/jido_cluster/issues/1) supplies application examples. Neither issue proves a runtime guarantee.

## Working rules

- Mark each proposal as proposed until a decision is recorded.
- Keep the implementation review separate from the desired design.
- Link each runtime claim to source code and executable evidence.
- Put each public contract in the package that owns it.
- Record a decision with its reason, alternatives, proof requirements, and affected packages.
- Do not copy Jido core runtime semantics into this package.
- Add living examples only for implemented public contracts. Put incomplete experiments in research examples.
- Update this folder when an accepted design or implementation changes.

These documents do not replace the [current foundation guide](../../guides/v3-foundation.md) or the [runnable examples](../../examples/README.md).
