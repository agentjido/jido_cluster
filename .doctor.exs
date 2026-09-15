%Doctor.Config{
  ignore_modules: [Jido.Cluster.Internal.LocalManager],
  min_module_doc_coverage: 80,
  min_module_spec_coverage: 80,
  min_overall_doc_coverage: 90,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 100,
  exception_moduledoc_required: true,
  struct_type_spec_required: true,
  reporter: Doctor.Reporters.Summary
}
