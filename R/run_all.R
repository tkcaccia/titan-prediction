.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
scripts <- c(
  "R/00_download_cbioportal.R",
  "R/01_build_patient_cohort.R",
  "R/01b_participant_characteristics.R",
  "R/02_build_nonmutation_targets.R",
  "R/03_build_mutation_targets.R",
  "R/04_screen_continuous.R",
  "R/05_screen_binary.R",
  "R/05b_refine_permutations.R",
  "R/06_robustness_and_models.R",
  "R/06b_performance_reporting.R",
  "R/07_site_grouped_sensitivity.R",
  "R/07b_slide_pooling_sensitivity.R",
  "R/08_pls1_vs_pls2_inflammation.R",
  "R/09_make_figures.R",
  "R/10_literature_crosswalk.R",
  "R/11_package_demo.R",
  "R/07_source_manifest.R"
)
for (script in scripts) {
  message("Running ", script)
  status <- system2(file.path(R.home("bin"), "Rscript"), script)
  if (!identical(status, 0L)) stop("Pipeline failed at ", script)
}
