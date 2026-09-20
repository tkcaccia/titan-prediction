# Run the matched comparison after restricting every representation to the
# exact slide intersection. Keeping this entry point explicit makes the
# dependency of R/18b visible in the full pipeline.
Sys.setenv(FMPRED_COHORT_MODE = "exact_common_slide")
source("R/16_compare_foundation_models.R", chdir = FALSE)

# Preserve the component-grid-labelled artifacts produced by the comparison,
# and refresh the canonical exact-slide handoff consumed by R/18b.
data.table::fwrite(
  results,
  "results/tables/foundation_model_matched_screen_exact_common_slide.csv"
)
saveRDS(
  predictions,
  "results/predictions/foundation_model_matched_oof_exact_common_slide.rds",
  compress = "xz"
)
data.table::fwrite(
  summary,
  "results/tables/foundation_model_matched_summary_exact_common_slide.csv"
)
