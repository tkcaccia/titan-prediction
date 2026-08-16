.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))
source("R/utils.R")

continuous_screen <- fread("results/tables/continuous_screen.csv")
binary_screen <- fread("results/tables/binary_screen.csv")
continuous_repeats <- fread("results/tables/continuous_repeated_nested_cv.csv")
binary_repeats <- fread("results/tables/binary_repeated_nested_cv.csv")
continuous_predictions <- fread(
  "results/predictions/continuous_repeated_oof_predictions.csv.gz"
)
binary_predictions <- fread(
  "results/predictions/binary_repeated_oof_predictions.csv.gz"
)
registry <- fread("models/model_registry.csv")

continuous_summary <- continuous_repeats[, .(
  repeated_q2_mean = mean(q2), repeated_q2_sd = sd(q2),
  repeated_q2_min = min(q2), repeated_q2_max = max(q2),
  repeated_rmse_mean = mean(rmse), repeated_rmse_sd = sd(rmse),
  repeated_spearman_mean = mean(spearman), repeated_spearman_sd = sd(spearman),
  nested_partitions = .N
), by = .(family, tumor_type, endpoint)]
continuous_summary <- merge(
  continuous_screen[tier %chin% c("A", "B")], continuous_summary,
  by = c("family", "tumor_type", "endpoint"), all.x = TRUE
)

binary_summary <- binary_repeats[, .(
  repeated_sensitivity_mean = mean(sensitivity),
  repeated_sensitivity_sd = sd(sensitivity),
  repeated_specificity_mean = mean(specificity),
  repeated_specificity_sd = sd(specificity),
  repeated_balanced_accuracy_mean = mean(balanced_accuracy),
  repeated_balanced_accuracy_sd = sd(balanced_accuracy),
  repeated_balanced_accuracy_min = min(balanced_accuracy),
  repeated_balanced_accuracy_max = max(balanced_accuracy),
  repeated_auc_mean = mean(auc), repeated_auc_sd = sd(auc),
  nested_partitions = .N
), by = .(family, tumor_type, endpoint)]
binary_summary <- merge(
  binary_screen[tier %chin% c("A", "B")], binary_summary,
  by = c("family", "tumor_type", "endpoint"), all.x = TRUE
)

continuous_summary[, outcome_type := "continuous"]
binary_summary[, outcome_type := "binary"]
summary_common <- rbindlist(list(continuous_summary, binary_summary),
                            use.names = TRUE, fill = TRUE)
summary_common <- merge(
  summary_common,
  registry[, .(family, tumor_type = cancer_type, endpoint, model_id, ncomp,
               model_file = file, model_sha256 = sha256, training_cohort,
               aggregation, feature_dimension, external_validation,
               titan_feature_file_sha256, feature_schema_sha256,
               prediction_rule, contains_patient_level_training_rows,
               endpoint_transform, output_units,
               model_fastPLS_version = fastPLS_version,
               model_fastPLS_remote_sha = fastPLS_remote_sha,
               model_backend = backend,
               model_svd_method = svd_method,
               model_rsvd_oversample = rsvd_oversample,
               model_rsvd_power = rsvd_power,
               model_fit_seed = fit_seed,
               model_analysis_fingerprint = analysis_fingerprint,
               class_labels, class_priors,
               calibration_status, intended_use, redistribution_status)],
  by = c("family", "tumor_type", "endpoint"), all.x = TRUE
)
summary_common[, evidence_label := fifelse(
  tier == "A", "within-cancer screen-positive, higher effect",
  "within-cancer screen-positive, moderate effect"
)]
setorder(summary_common, outcome_type, family, tumor_type, endpoint)
fwrite(summary_common,
       "results/tables/screen_positive_performance_summary.csv")

continuous_metric <- function(d) {
  mean_repeat_continuous_metrics(d)
}

binary_metric <- function(d) {
  mean_repeat_binary_metrics(d)
}

cluster_bootstrap <- function(d, metric_function, seed, times = 1000L) {
  ids <- unique(d$patient)
  split_rows <- split(seq_len(nrow(d)), d$patient)
  point <- metric_function(d)
  set.seed(seed)
  boot <- rbindlist(lapply(seq_len(times), function(i) {
    sampled <- sample(ids, length(ids), replace = TRUE)
    rows <- unlist(split_rows[sampled], use.names = FALSE)
    metric_function(d[rows])
  }))
  result <- copy(point)
  for (metric in names(point)) {
    set(result, j = paste0(metric, "_ci_low"),
        value = quantile(boot[[metric]], 0.025, na.rm = TRUE))
    set(result, j = paste0(metric, "_ci_high"),
        value = quantile(boot[[metric]], 0.975, na.rm = TRUE))
  }
  result
}

# These are the models named or plotted in the manuscript: the twelve largest
# screen effects for each outcome type. Metrics are calculated separately in
# each repeated nested-CV run and then averaged; in particular, LDA scores from
# independently fitted repeats are never pooled onto an assumed common scale.
# Uncertainty resamples patients as clusters, preserving all five predictions
# and repeating the within-repeat-then-average calculation.
highlighted_continuous <- head(
  continuous_screen[tier %chin% c("A", "B")][order(-q2)], 12L
)
highlighted_binary <- head(
  binary_screen[tier %chin% c("A", "B")][order(-balanced_accuracy)], 12L
)

continuous_ci <- rbindlist(lapply(seq_len(nrow(highlighted_continuous)), function(i) {
  job <- highlighted_continuous[i]
  d <- continuous_predictions[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  cbind(job[, .(family, tumor_type, endpoint, n, q_value, q_value_global,
                tier)],
        cluster_bootstrap(d, continuous_metric, 20260815L + i))
}))
continuous_ci[, outcome_type := "continuous"]

binary_ci <- rbindlist(lapply(seq_len(nrow(highlighted_binary)), function(i) {
  job <- highlighted_binary[i]
  d <- binary_predictions[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  cbind(job[, .(family, tumor_type, endpoint, n, positive, negative,
                q_value, q_value_global, tier)],
        cluster_bootstrap(d, binary_metric, 20261815L + i))
}))
binary_ci[, outcome_type := "binary"]

highlighted <- rbindlist(list(continuous_ci, binary_ci),
                         use.names = TRUE, fill = TRUE)
highlighted <- merge(
  highlighted,
  registry[, .(family, tumor_type = cancer_type, endpoint, model_id, ncomp,
               model_file = file, model_sha256 = sha256, training_cohort,
               aggregation, feature_dimension, external_validation,
               titan_feature_file_sha256, feature_schema_sha256,
               prediction_rule, contains_patient_level_training_rows,
               endpoint_transform, output_units,
               model_fastPLS_version = fastPLS_version,
               model_fastPLS_remote_sha = fastPLS_remote_sha,
               model_backend = backend,
               model_svd_method = svd_method,
               model_rsvd_oversample = rsvd_oversample,
               model_rsvd_power = rsvd_power,
               model_fit_seed = fit_seed,
               model_analysis_fingerprint = analysis_fingerprint,
               class_labels, class_priors,
               calibration_status, intended_use, redistribution_status)],
  by = c("family", "tumor_type", "endpoint"), all.x = TRUE
)
highlighted[, uncertainty_method := paste(
  "95% patient-cluster bootstrap percentile interval for the mean of five",
  "repeat-specific nested-CV metrics; 1000 resamples"
)]
setorder(highlighted, outcome_type, -q2, -balanced_accuracy)
fwrite(highlighted,
       "results/tables/highlighted_model_performance.csv")

cat("performance summaries:", nrow(summary_common),
    "screen-positive models;", nrow(highlighted), "highlighted models\n")
