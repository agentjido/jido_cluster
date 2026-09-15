cluster_locals = [cluster_worker: 2, cluster_worker: 3]

[
  import_deps: [:jido, :jido_action],
  locals_without_parens: cluster_locals,
  export: [locals_without_parens: cluster_locals],
  inputs: [
    "{mix,.formatter,.credo,.doctor}.exs",
    "{config,lib,test,examples}/**/*.{ex,exs}"
  ],
  line_length: 120
]
