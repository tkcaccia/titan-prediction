.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()
component_ceiling <- max(as.integer(cfg$analysis$components))

sensitivity <- fread("results/tables/binary_decision_rule_sensitivity.csv")
fastpls_description <- packageDescription("fastPLS")
fastpls_remote_sha <- as.character(fastpls_description$RemoteSha)
sensitivity[, `:=`(
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = fastpls_remote_sha
)]
fwrite(sensitivity, "results/tables/binary_decision_rule_sensitivity.csv")
expected <- 459L + 3L * 426L
if (nrow(sensitivity) != expected) {
  stop("Expected ", expected, " complete decision-rule rows; found ", nrow(sensitivity))
}

metadata_columns <- c(
  "recomputed_primary_balanced_accuracy", "primary_sensitivity",
  "primary_specificity", "primary_auc", "primary_pr_auc",
  "equal_prior_balanced_accuracy", "equal_prior_sensitivity",
  "equal_prior_specificity", "equal_prior_auc", "equal_prior_pr_auc",
  "optimized_balanced_accuracy", "optimized_sensitivity",
  "optimized_specificity", "optimized_auc", "optimized_pr_auc",
  "recomputed_primary_crossing", "equal_prior_crossing", "optimized_crossing",
  "median_primary_component", "median_equal_component",
  "median_optimized_component", "median_optimized_threshold",
  "primary_components_at_ceiling", "equal_components_at_ceiling",
  "optimized_components_at_ceiling", "equal_prior_delta_ba",
  "optimized_delta_ba", "optimized_membership_change",
  "equal_prior_membership_change"
)
key <- c("foundation_model", "family", "tumor_type", "endpoint")
drop_if_present <- function(x, columns) {
  present <- intersect(columns, names(x))
  if (length(present)) x[, (present) := NULL]
  x
}

full <- fread("results/tables/binary_screen.csv")
full <- drop_if_present(full, c(
  metadata_columns, "foundation_model", "primary_binary_decision_rule",
  "decision_rule_sensitivity_scope", "decision_rule_sensitivity_status"
))
full_sensitivity <- sensitivity[layer == "TITAN permutation/FDR screen"]
stopifnot(nrow(full_sensitivity) == nrow(full))
full_join <- full_sensitivity[, c(key, metadata_columns), with = FALSE]
full <- merge(
  full, full_join,
  by.x = c("family", "tumor_type", "endpoint"),
  by.y = c("family", "tumor_type", "endpoint"), all.x = TRUE, sort = FALSE
)
if (anyNA(full$recomputed_primary_balanced_accuracy)) {
  stop("A TITAN binary screen row lacks decision-rule metadata")
}
max_delta <- max(abs(
  full$balanced_accuracy - full$recomputed_primary_balanced_accuracy
))
if (max_delta > 1e-10) {
  stop("Current-package TITAN screen was not reproduced; maximum BA delta=", max_delta)
}
full[, `:=`(
  foundation_model = NULL,
  fastPLS_remote_sha = fastpls_remote_sha,
  primary_binary_decision_rule = "empirical outer-training-fold LDA priors",
  decision_rule_sensitivity_scope = paste0(
    "complete eligible binary atlas; equal-prior and inner-OOF optimized-threshold rules; ",
    "alternative crossings are not permutation/FDR-qualified"
  ),
  decision_rule_sensitivity_status = fifelse(
    optimized_membership_change | equal_prior_membership_change,
    "effect-threshold membership sensitive to operating rule",
    "effect-threshold membership retained under both alternative rules"
  )
)]
setorder(full, family, -balanced_accuracy)
fwrite(full, "results/tables/binary_screen.csv")

matched <- fread("results/tables/foundation_model_matched_screen.csv")
matched <- drop_if_present(matched, c(
  metadata_columns, "primary_binary_decision_rule",
  "decision_rule_sensitivity_scope", "decision_rule_sensitivity_status"
))
matched_sensitivity <- sensitivity[layer == "matched three-representation atlas"]
stopifnot(nrow(matched_sensitivity) == 3L * 426L)
matched_join <- matched_sensitivity[, c(key, metadata_columns), with = FALSE]
matched <- merge(matched, matched_join, by = key, all.x = TRUE, sort = FALSE)
binary_rows <- matched$outcome_type == "binary"
if (anyNA(matched$recomputed_primary_balanced_accuracy[binary_rows])) {
  stop("A matched binary row lacks current-package decision-rule metadata")
}
matched[binary_rows, `:=`(
  balanced_accuracy = recomputed_primary_balanced_accuracy,
  auc = primary_auc,
  pr_auc = primary_pr_auc,
  selected_components_median = median_primary_component
)]
folds <- fread("results/tables/binary_decision_rule_fold_thresholds.csv")
matched_fold_summary <- folds[layer == "matched three-representation atlas", .(
  selected_components_min_current = min(primary_component),
  selected_components_max_current = max(primary_component),
  selected_components_at_ceiling_current = sum(primary_component == component_ceiling),
  selected_components_outer_fits_current = .N,
  selected_components_ceiling_fraction_current = mean(primary_component == component_ceiling)
), by = key]
matched <- merge(matched, matched_fold_summary, by = key, all.x = TRUE, sort = FALSE)
matched[binary_rows, `:=`(
  selected_components_min = selected_components_min_current,
  selected_components_max = selected_components_max_current,
  selected_components_at_ceiling = selected_components_at_ceiling_current,
  selected_components_outer_fits = selected_components_outer_fits_current,
  selected_components_ceiling_fraction = selected_components_ceiling_fraction_current,
  fastPLS_version_current = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha_current = fastpls_remote_sha,
  primary_binary_decision_rule = "empirical outer-training-fold LDA priors",
  decision_rule_sensitivity_scope = paste0(
    "complete matched binary atlas; equal-prior and inner-OOF optimized-threshold rules"
  ),
  decision_rule_sensitivity_status = fifelse(
    optimized_membership_change | equal_prior_membership_change,
    "effect-threshold membership sensitive to operating rule",
    "effect-threshold membership retained under both alternative rules"
  )
)]
matched[, c(
  "selected_components_min_current", "selected_components_max_current",
  "selected_components_at_ceiling_current",
  "selected_components_outer_fits_current",
  "selected_components_ceiling_fraction_current"
) := NULL]
setorder(matched, outcome_type, family, tumor_type, endpoint, foundation_model)
fwrite(matched, "results/tables/foundation_model_matched_screen.csv")

matched_oof_path <- "results/predictions/foundation_model_matched_oof.rds"
if (file.exists(matched_oof_path)) {
  old_oof <- as.data.table(readRDS(matched_oof_path))
  decision_oof <- as.data.table(readRDS(
    "results/predictions/binary_decision_rule_sensitivity_oof.rds"
  ))[layer == "matched three-representation atlas"]
  binary_identity <- unique(matched[outcome_type == "binary", .(
    foundation_model, family, subfamily, tumor_type, endpoint, source
  )])
  decision_oof <- merge(
    decision_oof, binary_identity,
    by = c("foundation_model", "family", "tumor_type", "endpoint"),
    all.x = TRUE, sort = FALSE
  )
  decision_oof[, `:=`(
    outcome_type = "binary", predicted = NA_real_,
    predicted_class = primary_call, score = primary_score
  )]
  decision_oof <- decision_oof[, .(
    foundation_model, patient, observed, predicted, predicted_class, score,
    outer_fold, outcome_type, family, subfamily, tumor_type, endpoint, source
  )]
  old_oof <- old_oof[outcome_type != "binary"]
  refreshed_oof <- rbindlist(list(old_oof, decision_oof), use.names = TRUE, fill = TRUE)
  setorder(
    refreshed_oof, outcome_type, family, tumor_type, endpoint,
    foundation_model, patient
  )
  saveRDS(refreshed_oof, matched_oof_path, compress = "xz")
}

summary <- matched[, .(
  eligible_targets = .N,
  screen_statistic_ge_tier_B = if (outcome_type[1L] == "continuous") {
    sum(q2 >= 0.20, na.rm = TRUE)
  } else sum(balanced_accuracy >= 0.60, na.rm = TRUE),
  screen_statistic_ge_tier_A = if (outcome_type[1L] == "continuous") {
    sum(q2 >= 0.40, na.rm = TRUE)
  } else sum(balanced_accuracy >= 0.70, na.rm = TRUE),
  median_q2 = median(q2, na.rm = TRUE),
  median_auc = median(auc, na.rm = TRUE),
  median_balanced_accuracy = median(balanced_accuracy, na.rm = TRUE),
  median_pr_auc = median(pr_auc, na.rm = TRUE)
), by = .(foundation_model, outcome_type)]
fwrite(summary, "results/tables/foundation_model_matched_summary.csv")

registry_path <- "models/model_registry.csv"
if (file.exists(registry_path)) {
  registry <- fread(registry_path)
  registry <- drop_if_present(registry, c(
    metadata_columns, "primary_binary_decision_rule",
    "decision_rule_sensitivity_status"
  ))
  registry_binary <- full_sensitivity[, c(
    "family", "tumor_type", "endpoint", metadata_columns
  ), with = FALSE]
  registry <- merge(
    registry, registry_binary,
    by.x = c("family", "cancer_type", "endpoint"),
    by.y = c("family", "tumor_type", "endpoint"),
    all.x = TRUE, sort = FALSE
  )
  registry[outcome_type == "binary", `:=`(
    primary_binary_decision_rule = "empirical outer-training-fold LDA priors",
    decision_rule_sensitivity_status = fifelse(
      optimized_membership_change | equal_prior_membership_change,
      "effect-threshold membership sensitive to operating rule",
      "effect-threshold membership retained under both alternative rules"
    )
  )]
  setorder(registry, outcome_type, family, cancer_type, endpoint)
  fwrite(registry, registry_path)
}

foundation_registry_path <- "models/foundation_models/model_registry_additions.csv"
if (file.exists(foundation_registry_path)) {
  foundation_registry <- fread(foundation_registry_path)
  foundation_registry <- drop_if_present(foundation_registry, c(
    metadata_columns, "primary_binary_decision_rule",
    "decision_rule_sensitivity_status"
  ))
  foundation_registry <- merge(
    foundation_registry,
    matched_sensitivity[, c(key, metadata_columns), with = FALSE],
    by.x = c("foundation_model", "family", "cancer_type", "endpoint"),
    by.y = key, all.x = TRUE, sort = FALSE
  )
  foundation_registry[outcome_type == "binary", `:=`(
    screen_balanced_accuracy = recomputed_primary_balanced_accuracy,
    binary_pr_auc = primary_pr_auc,
    primary_binary_decision_rule = "empirical outer-training-fold LDA priors",
    decision_rule_sensitivity_status = fifelse(
      optimized_membership_change | equal_prior_membership_change,
      "effect-threshold membership sensitive to operating rule",
      "effect-threshold membership retained under both alternative rules"
    )
  )]
  setorder(
    foundation_registry, foundation_model, outcome_type, family,
    cancer_type, endpoint
  )
  fwrite(foundation_registry, foundation_registry_path)
}

cat(
  "Attached current-package binary performance and operating-rule sensitivity; ",
  "maximum TITAN reproduction delta=", format(max_delta, scientific = TRUE), "\n",
  sep = ""
)
