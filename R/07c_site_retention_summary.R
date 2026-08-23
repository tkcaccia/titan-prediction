.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()

continuous <- fread("results/tables/continuous_site_grouped_sensitivity.csv")
binary <- fread("results/tables/binary_site_grouped_sensitivity.csv")

continuous[, `:=`(
  outcome_type = "continuous",
  original_metric = random_q2,
  site_grouped_metric = site_grouped_q2,
  retention_threshold = cfg$analysis$continuous_effect_gate,
  retained_effect = feasible & is.finite(site_grouped_q2) &
    site_grouped_q2 >= cfg$analysis$continuous_effect_gate,
  near_chance_or_worse = feasible & is.finite(site_grouped_q2) &
    site_grouped_q2 <= 0
)]
binary[, `:=`(
  outcome_type = "binary",
  original_metric = random_balanced_accuracy,
  site_grouped_metric = site_grouped_balanced_accuracy,
  retention_threshold = (cfg$analysis$binary_adjusted_ba_gate + 1) / 2,
  retained_effect = feasible & is.finite(site_grouped_balanced_accuracy) &
    site_grouped_balanced_accuracy >=
      (cfg$analysis$binary_adjusted_ba_gate + 1) / 2,
  near_chance_or_worse = feasible & is.finite(site_grouped_balanced_accuracy) &
    site_grouped_balanced_accuracy <= 0.55
)]

common <- c(
  "outcome_type", "family", "tumor_type", "endpoint", "n", "n_sites",
  "original_metric", "site_grouped_metric", "delta", "retention_threshold",
  "retained_effect", "near_chance_or_worse", "feasible",
  "outer_site_overlap", "seed", "backend", "svd_method",
  "rsvd_oversample", "rsvd_power"
)
models <- rbindlist(list(continuous[, ..common], binary[, ..common]),
                        use.names = TRUE, fill = TRUE)
models[, retention_definition := fifelse(
  outcome_type == "continuous", "site-grouped Q2 >= 0.20",
  "site-grouped balanced accuracy >= 0.60"
)]
setorder(models, retained_effect, site_grouped_metric)
fwrite(models[retained_effect == FALSE],
       "results/tables/site_grouped_models_below_effect_threshold.csv")

summarize <- function(d, label) {
  data.table(
    outcome_type = label,
    screen_positive_models = nrow(d),
    feasible_models = sum(d$feasible),
    retained_models = sum(d$retained_effect),
    below_threshold_models = sum(!d$retained_effect),
    below_threshold_percent = 100 * mean(!d$retained_effect),
    near_chance_or_worse_models = sum(d$near_chance_or_worse),
    median_delta = median(d$delta, na.rm = TRUE)
  )
}
summary <- rbindlist(list(
  summarize(continuous, "continuous"),
  summarize(binary, "binary"),
  summarize(models, "combined")
))
fwrite(summary, "results/tables/site_grouped_retention_summary.csv")

stopifnot(!any(models$outer_site_overlap, na.rm = TRUE))
print(summary)
