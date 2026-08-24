suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

continuous <- fread("results/tables/continuous_site_grouped_sensitivity.csv")
binary <- fread("results/tables/binary_site_grouped_sensitivity.csv")
folds <- fread("results/tables/site_grouped_fold_composition_summary.csv")

continuous_site <- continuous[, .(
  family, tumor_type, endpoint,
  site_grouped_metric_name = "Q2",
  site_grouped_metric = site_grouped_q2,
  site_performance_delta = delta,
  site_grouped_n_sites = n_sites,
  site_grouped_feasible = feasible,
  site_retained_effect = feasible & is.finite(site_grouped_q2) &
    site_grouped_q2 >= cfg$analysis$continuous_effect_gate,
  site_near_chance_or_worse = feasible & is.finite(site_grouped_q2) &
    site_grouped_q2 <= 0
)]
binary_site <- binary[, .(
  family, tumor_type, endpoint,
  site_grouped_metric_name = "balanced accuracy",
  site_grouped_metric = site_grouped_balanced_accuracy,
  site_performance_delta = delta,
  site_grouped_n_sites = n_sites,
  site_grouped_feasible = feasible,
  site_retained_effect = feasible & is.finite(site_grouped_balanced_accuracy) &
    site_grouped_balanced_accuracy >= (cfg$analysis$binary_adjusted_ba_gate + 1) / 2,
  site_near_chance_or_worse = feasible & is.finite(site_grouped_balanced_accuracy) &
    site_grouped_balanced_accuracy <= 0.55
)]
site <- rbindlist(list(continuous_site, binary_site), use.names = TRUE)
site[, site_robustness_status := fcase(
  !site_grouped_feasible, "not evaluable",
  site_near_chance_or_worse, "site-sensitive: near chance or worse",
  !site_retained_effect, "site-sensitive: below original effect threshold",
  default = "retained original effect threshold"
)]
site[, site_robustness_warning := fcase(
  !site_grouped_feasible,
  "TCGA tissue-source-site-grouped internal validation was not feasible.",
  site_near_chance_or_worse,
  "Prominent site-sensitivity warning: performance was near chance or worse under TCGA tissue-source-site grouping.",
  !site_retained_effect,
  "Site-sensitivity warning: performance fell below the original effect threshold under TCGA tissue-source-site grouping.",
  default = ""
)]
site[, site_grouped_validation_scope := paste(
  "TCGA tissue-source-site-grouped internal validation;",
  "not institutional or scanner-level external validation"
)]

fold_fields <- folds[, .(
  family, tumor_type, endpoint,
  site_grouped_outer_folds = outer_folds,
  site_grouped_minimum_test_patients = minimum_test_patients,
  site_grouped_maximum_test_patients = maximum_test_patients,
  site_grouped_minimum_test_sites = minimum_test_sites,
  site_grouped_maximum_test_sites = maximum_test_sites,
  site_grouped_minimum_test_positive = minimum_test_positive,
  site_grouped_maximum_test_positive = maximum_test_positive,
  site_grouped_inner_site_separation = inner_site_grouped
)]
site <- merge(site, fold_fields,
              by = c("family", "tumor_type", "endpoint"), all.x = TRUE)

attach_site <- function(path, cancer_column) {
  d <- fread(path)
  if (cancer_column == "cancer_type") setnames(d, "cancer_type", "tumor_type")
  old <- intersect(names(d), setdiff(names(site), c("family", "tumor_type", "endpoint")))
  if (length(old)) d[, (old) := NULL]
  d <- merge(d, site, by = c("family", "tumor_type", "endpoint"), all.x = TRUE)
  if (cancer_column == "cancer_type") setnames(d, "tumor_type", "cancer_type")
  fwrite(d, path)
}

attach_site("models/model_registry.csv", "cancer_type")
attach_site("results/tables/screen_positive_performance_summary.csv", "tumor_type")
attach_site("results/tables/highlighted_model_performance.csv", "tumor_type")

registry <- fread("models/model_registry.csv")
stopifnot(nrow(registry) == nrow(site),
          all(!is.na(registry$site_robustness_status)),
          all(registry$site_grouped_inner_site_separation))
cat("Attached site-robustness metadata to", nrow(registry), "registered models.\n")
