# Errors

The error surface gives the package one consistent set of exception helpers
across the preferred public facade and the legacy implementation module.

## Intent

This subject covers the public `Jido.Cluster.Error` facade, the legacy
`JidoCluster.Error` implementation, and the typed exception helpers it exposes.

```spec-meta
id: jido_cluster.errors
kind: module
status: active
summary: Public and legacy error helpers return typed exceptions for validation, config, and execution failures.
surface:
  - lib/jido/cluster/error.ex
  - lib/jido_cluster/error.ex
  - test/jido_cluster/error_test.exs
```

## Requirements

```spec-requirements
- id: jido_cluster.errors.public_error_facade
  statement: The preferred Jido.Cluster.Error namespace shall expose validation_error, config_error, and execution_error helpers.
  priority: must
  stability: stable

- id: jido_cluster.errors.typed_exception_results
  statement: Error helper calls shall return typed exceptions for invalid input, configuration failures, and runtime execution failures.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: source_file
  target: lib/jido/cluster/error.ex
  covers:
    - jido_cluster.errors.public_error_facade

- kind: command
  target: mix test test/jido_cluster/error_test.exs
  execute: true
  covers:
    - jido_cluster.errors.public_error_facade
    - jido_cluster.errors.typed_exception_results
```
