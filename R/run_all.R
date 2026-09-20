.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
for (directory in c(
  "data/processed", "results/tables", "results/predictions",
  "results/figures", "results/reports", "models/foundation_models",
  "models/histology_context", "figures"
)) {
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
}
scripts <- c(
  "R/00_download_cbioportal.R",
  "R/00a_download_pathway_rnaseq.R",
  "R/01_build_patient_cohort.R",
  "R/01b_participant_characteristics.R",
  "R/02a_build_pathway_activity_targets.R",
  "R/02_build_nonmutation_targets.R",
  "R/03_build_mutation_targets.R",
  "R/02b_molecular_slide_linkage_audit.R",
  "R/04_screen_continuous.R",
  "R/05_screen_binary.R",
  "R/05b_refine_permutations.R",
  "R/05c_targeted_permutation_refinement.R",
  "R/05d_audit_multiplicity_denominators.R",
  "R/06_robustness_and_models.R",
  "R/06c_binary_class_reliability.R",
  "R/06d_continuous_reliability.R",
  "R/06b_performance_reporting.R",
  "R/07_site_grouped_sensitivity.R",
  "R/07c_site_retention_summary.R",
  "R/07d_site_fold_audit.R",
  "R/07e_tissue_source_site_predictability.R",
  "R/07g_site_partition_controls.R",
  "R/07f_attach_site_metadata.R",
  "R/07b_slide_pooling_sensitivity.R",
  "R/07h_slide_embedding_heterogeneity.R",
  "R/07i_median_pooling_and_sarc_exclusion.R",
  "R/08_pls1_vs_pls2_inflammation.R",
  "R/08b_exportable_ridge_baselines.R",
  "R/12_subgroup_performance.R",
  "R/14_pathology_qc_audit.R",
  "R/14b_no_residual_narrative_sensitivity.R",
  "R/15_build_foundation_model_cohorts.R",
  "R/15b_audit_common_slide_sets.R",
  "R/16_compare_foundation_models.R",
  "R/16c_audit_probe_dependence.R",
  "R/19_binary_decision_rule_sensitivity.R",
  "R/19b_attach_binary_decision_rule_metadata.R",
  "R/19f_matched_binary_auroc_tuned_sensitivity.R",
  "R/19i_promote_auroc_primary.R",
  # The comparison summaries join endpoint provenance metadata generated here.
  # Build the dictionary before the first R/18 summary stage.
  "R/13_endpoint_dictionary_and_morphology.R",
  "R/18_summarise_foundation_model_comparison.R",
  "R/18c_summarise_evidence_maturity.R",
  "R/16d_foundation_model_fold_threshold_stability.R",
  "R/16e_foundation_model_tss_grouped_sensitivity.R",
  "R/19h_audit_grouped_fold_adequacy.R",
  # Rebuild comparison tables and figures with the refreshed grouped results.
  "R/18_summarise_foundation_model_comparison.R",
  "R/19g_effect_partition_presentation.R",
  "R/16b_compare_foundation_models_exact_common_slide.R",
  "R/18b_summarise_exact_common_slide_sensitivity.R",
  "R/17_fit_foundation_model_resource.R",
  # R/17 rewrites the alternative-representation registry. Reapply the
  # AUROC-centred matched metrics and operating-rule metadata.
  "R/19i_promote_auroc_primary.R",
  "R/19d_attach_matched_tss_metadata.R",
  "R/19c_refresh_model_inventory.R",
  "R/19e_audit_fitted_model_target_universe.R",
  "R/21_make_biological_predictability_figure.R",
  "R/09_make_figures.R",
  "R/09b_continuous_reliability_figure.R",
  "R/10_literature_crosswalk.R",
  "R/11_package_demo.R",
  "R/11b_multifoundation_coad_demo.R",
  "R/07_source_manifest.R"
)
start_script <- Sys.getenv("TITAN_START_SCRIPT", unset = "")
if (nzchar(start_script)) {
  start_position <- match(start_script, scripts)
  if (is.na(start_position)) stop("Unknown TITAN_START_SCRIPT: ", start_script)
  scripts <- scripts[seq.int(start_position, length(scripts))]
  message("Resuming pipeline from ", start_script)
}
for (script in scripts) {
  message("Running ", script)
  status <- system2(file.path(R.home("bin"), "Rscript"), script)
  if (!identical(status, 0L)) stop("Pipeline failed at ", script)
  if (identical(script, "R/19e_audit_fitted_model_target_universe.R")) {
    python <- Sys.which("python3")
    if (!nzchar(python)) stop("python3 is required to synchronize PathoFMPred")
    status <- system2(python, "tools/sync_pathofmpred_registry.py")
    if (!identical(status, 0L)) {
      stop("Pipeline failed while synchronizing PathoFMPred fitted objects")
    }
    # Rebuild the package registry and the empirical out-of-fold reference
    # distributions together. Copying the registry and fitted objects alone
    # leaves prediction ranks undefined in a clean installation.
    status <- system2(
      file.path(R.home("bin"), "Rscript"),
      c(
        "../TITANPred/tools/build_package_data.R",
        normalizePath(".", mustWork = TRUE),
        normalizePath("../TITANPred", mustWork = TRUE)
      )
    )
    if (!identical(status, 0L)) {
      stop("Pipeline failed while rebuilding PathoFMPred package data")
    }
    status <- system2(
      file.path(R.home("bin"), "R"),
      c("CMD", "INSTALL", "--library=.Rlib", "../TITANPred")
    )
    if (!identical(status, 0L)) {
      stop("Pipeline failed while installing the refreshed PathoFMPred package")
    }
  }
}
python <- Sys.which("python3")
if (!nzchar(python)) stop("python3 is required for the translational consensus tables")
status <- system2(python, "tools/sync_pathofmpred_registry.py")
if (!identical(status, 0L)) stop("Pipeline failed at tools/sync_pathofmpred_registry.py")
status <- system2(python, "tools/build_translational_consensus.py")
if (!identical(status, 0L)) stop("Pipeline failed at tools/build_translational_consensus.py")
