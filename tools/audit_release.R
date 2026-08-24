.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(digest)
})
source("R/utils.R")
cfg <- load_project_config()
fastpls_description <- packageDescription("fastPLS")

assert <- function(ok, message) {
  if (!isTRUE(ok)) stop(message, call. = FALSE)
}
assert(identical(cfg$analysis$svd_method, "rsvd") &&
         identical(cfg$analysis$rsvd_oversample, 10L) &&
         identical(cfg$analysis$rsvd_power, 2L),
       "Analysis configuration is not rSVD-only with the prespecified controls")
r_sources <- list.files("R", pattern = "[.]R$", full.names = TRUE)
assert(!any(vapply(r_sources, function(path) {
  any(grepl("irlba", readLines(path, warn = FALSE), ignore.case = TRUE))
}, logical(1))), "An R analysis script still references IRLBA")
key <- c("family", "tumor_type", "endpoint")
assert(as.character(packageVersion("fastPLS")) == "0.99.20",
       "Project-local fastPLS is not version 0.99.20")
fastpls_sha <- if (is.null(fastpls_description$RemoteSha)) "" else
  as.character(fastpls_description$RemoteSha)
assert(startsWith(fastpls_sha, "dcf45cc"),
       "Project-local fastPLS is not built from commit dcf45cc")

continuous <- fread("results/tables/continuous_screen.csv")
binary <- fread("results/tables/binary_screen.csv")
screen_backends <- unique(c(continuous$backend, binary$backend))
assert(length(screen_backends) == 1L && !is.na(screen_backends) &&
         nzchar(screen_backends),
       "Continuous and binary screens do not share one recorded backend")
cohort_object <- readRDS("data/processed/patient_cohort.rds")
expected_analysis_fingerprint <- digest(list(
  checkpoint_schema = 2L,
  script_sha256 = digest(
    file = "R/06_robustness_and_models.R", algo = "sha256"
  ),
  utils_sha256 = digest(file = "R/utils.R", algo = "sha256"),
  cohort_sha256 = digest(
    file = "data/processed/patient_cohort.rds", algo = "sha256"
  ),
  continuous_targets_sha256 = digest(
    file = "data/processed/continuous_targets.rds", algo = "sha256"
  ),
  binary_nonmutation_targets_sha256 = digest(
    file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"
  ),
  binary_mutation_targets_sha256 = digest(
    file = "data/processed/binary_targets_mutation.rds", algo = "sha256"
  ),
  continuous_screen_sha256 = digest(
    file = "results/tables/continuous_screen.csv", algo = "sha256"
  ),
  binary_screen_sha256 = digest(
    file = "results/tables/binary_screen.csv", algo = "sha256"
  ),
  analysis = cfg$analysis,
  feature_names = cohort_object$feature_names,
  cohort_source_sha256 = cohort_object$source_sha256,
  patient_ids = rownames(cohort_object$X),
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = fastpls_sha,
  backend = screen_backends
), algo = "sha256")
assert(uniqueN(continuous, by = key) == nrow(continuous),
       "Duplicate continuous endpoint keys")
assert(uniqueN(binary, by = key) == nrow(binary),
       "Duplicate binary endpoint keys")

continuous_catalog <- fread("results/tables/continuous_target_catalog.csv")[
  n >= cfg$analysis$continuous_min_n & is.finite(sd) & sd > 0
]
assert(nrow(continuous) == nrow(continuous_catalog) &&
         nrow(fsetdiff(continuous[, c(key, "n"), with = FALSE],
                       continuous_catalog[, c(key, "n"), with = FALSE])) == 0L &&
         nrow(fsetdiff(continuous_catalog[, c(key, "n"), with = FALSE],
                       continuous[, c(key, "n"), with = FALSE])) == 0L,
       "Continuous screen keys or denominators do not match the eligible catalogue")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
binary_catalog <- binary_targets[, .(
  n = .N, positive = sum(value == 1L), negative = sum(value == 0L)
), by = key][
  positive >= cfg$analysis$binary_min_positive &
    negative >= cfg$analysis$binary_min_negative
]
binary_denominators <- c(key, "n", "positive", "negative")
assert(nrow(binary) == nrow(binary_catalog) &&
         nrow(fsetdiff(binary[, ..binary_denominators],
                       binary_catalog[, ..binary_denominators])) == 0L &&
         nrow(fsetdiff(binary_catalog[, ..binary_denominators],
                       binary[, ..binary_denominators])) == 0L,
       "Binary screen keys or class denominators do not match eligible targets")

audit_permutations <- function(z, effect_ok, label) {
  assert("backend" %in% names(z) && all(!is.na(z$backend) & nzchar(z$backend)),
         paste(label, "has incomplete computation-backend metadata"))
  assert("fastPLS_version" %in% names(z) &&
           all(z$fastPLS_version == as.character(packageVersion("fastPLS"))),
         paste(label, "does not match the project-local fastPLS version"))
  assert("svd_method" %in% names(z) &&
           all(z$svd_method == cfg$analysis$svd_method) &&
           all(z$rsvd_oversample == cfg$analysis$rsvd_oversample) &&
           all(z$rsvd_power == cfg$analysis$rsvd_power),
         paste(label, "does not record the prespecified rSVD configuration"))
  assert(all(is.finite(z$p_permutation) & z$p_permutation >= 0 &
               z$p_permutation <= 1), paste(label, "has invalid p values"))
  assert(all(is.finite(z$q_value) & z$q_value >= 0 & z$q_value <= 1),
         paste(label, "has invalid within-cancer q values"))
  assert(all(is.finite(z$q_value_global) & z$q_value_global >= 0 &
               z$q_value_global <= 1),
         paste(label, "has invalid global q values"))
  assert(all(z$permutations[effect_ok] == cfg$analysis$extended_permutations),
         paste(label, "effect-eligible rows were not finalized at the 999 target"))
  assert(all(z$permutations[!effect_ok] == 0L),
         paste(label, "non-effect rows unexpectedly entered permutation testing"))
  assert(all(z$permutation_attempted[effect_ok] > 0L &
               z$permutation_attempted[effect_ok] <= z$permutations[effect_ok]),
         paste(label, "has invalid attempted-permutation metadata"))
  completed <- effect_ok & !z$permutation_stopped_early
  expected_p <- (z$permutation_exceedances[completed] + 1) /
    (z$permutations[completed] + 1)
  assert(all(abs(z$p_permutation[completed] - expected_p) < 1e-12),
         paste(label, "does not reproduce the finite-permutation p-value formula"))
  stopped <- effect_ok & z$permutation_stopped_early
  assert(all(z$p_permutation[stopped] == 1 &
               z$permutation_attempted[stopped] < z$permutations[stopped] &
               z$permutation_exceedances[stopped] >= 49L),
         paste(label, "has inconsistent conservative early-stop metadata"))
}
audit_permutations(
  continuous, is.finite(continuous$q2) &
    continuous$q2 >= cfg$analysis$continuous_effect_gate,
  "continuous screen"
)
audit_permutations(
  binary, is.finite(binary$adjusted_balanced_accuracy) &
    binary$adjusted_balanced_accuracy >= cfg$analysis$binary_adjusted_ba_gate,
  "binary screen"
)

supported_c <- continuous[tier %chin% c("A", "B")]
supported_b <- binary[tier %chin% c("A", "B")]
supported <- rbindlist(list(
  supported_c[, c(key), with = FALSE], supported_b[, c(key), with = FALSE]
))

registry <- fread("models/model_registry.csv")
setnames(registry, "cancer_type", "tumor_type")
assert(uniqueN(registry, by = key) == nrow(registry),
       "Duplicate model-registry keys")
assert(nrow(registry) == nrow(supported),
       "Model registry does not contain exactly the screen-positive endpoints")
assert(nrow(fsetdiff(registry[, ..key], supported)) == 0L &&
         nrow(fsetdiff(supported, registry[, ..key])) == 0L,
       "Model registry and screen-positive endpoint keys differ")
assert(all(registry$feature_dimension == cfg$analysis$expected_features),
       "Model registry contains an unexpected feature dimension")
assert(all(registry$contains_patient_level_training_rows == FALSE),
       "Registry says at least one artifact retains patient-level training rows")
assert(all(!is.na(registry$endpoint_transform) & nzchar(registry$endpoint_transform) &
             !is.na(registry$output_units) & nzchar(registry$output_units)),
       "Registry endpoint transformation/output units are incomplete")
assert(all(registry$fastPLS_version == "0.99.20" &
             startsWith(registry$fastPLS_remote_sha, "dcf45cc") &
             !is.na(registry$backend) & nzchar(registry$backend)),
       "Registry software-version, commit or backend metadata are incomplete")
assert("svd_method" %in% names(registry) &&
         all(registry$svd_method == cfg$analysis$svd_method) &&
         all(registry$rsvd_oversample == cfg$analysis$rsvd_oversample) &&
         all(registry$rsvd_power == cfg$analysis$rsvd_power) &&
         all(is.finite(registry$fit_seed)),
       "Registry does not record the prespecified rSVD configuration")
assert("analysis_fingerprint" %in% names(registry) &&
         all(!is.na(registry$analysis_fingerprint) &
               nzchar(registry$analysis_fingerprint)) &&
         uniqueN(registry$analysis_fingerprint) == 1L &&
         registry$analysis_fingerprint[1L] == expected_analysis_fingerprint,
       "Registry analysis fingerprints are missing or inconsistent")
binary_registry <- registry[outcome_type == "binary"]
assert(all(!is.na(binary_registry$class_labels) &
             nzchar(binary_registry$class_labels) &
             !is.na(binary_registry$class_priors) &
             nzchar(binary_registry$class_priors)),
       "Binary registry class coding or priors are incomplete")
assert(all(!is.na(registry$calibration_status) &
             nzchar(registry$calibration_status) &
             !is.na(registry$intended_use) & nzchar(registry$intended_use)),
       "Registry calibration or intended-use metadata are incomplete")
site_registry_fields <- c(
  "site_grouped_metric_name", "site_grouped_metric", "site_performance_delta",
  "site_grouped_n_sites", "site_grouped_feasible", "site_retained_effect",
  "site_near_chance_or_worse", "site_robustness_status",
  "site_robustness_warning", "site_grouped_validation_scope",
  "site_grouped_outer_folds", "site_grouped_minimum_test_patients",
  "site_grouped_maximum_test_patients", "site_grouped_minimum_test_sites",
  "site_grouped_maximum_test_sites", "site_grouped_inner_site_separation"
)
assert(all(site_registry_fields %chin% names(registry)),
       "Model registry lacks tissue-source-site robustness fields")
assert(all(is.finite(registry$site_grouped_metric) &
             is.finite(registry$site_performance_delta) &
             registry$site_grouped_n_sites >= 2L &
             registry$site_grouped_inner_site_separation &
             grepl("TCGA tissue-source-site-grouped internal validation",
                   registry$site_grouped_validation_scope, fixed = TRUE)),
       "Model registry contains incomplete site-robustness metadata")
assert(all(nzchar(registry$site_robustness_warning[
  grepl("^site-sensitive", registry$site_robustness_status)
])), "Site-sensitive registry rows lack prominent warnings")

for (i in seq_len(nrow(registry))) {
  path <- registry$file[i]
  assert(file.exists(path), paste("Missing local model artifact:", path))
  assert(digest(file = path, algo = "sha256") == registry$sha256[i],
         paste("Model hash mismatch:", path))
  artifact <- readRDS(path)
  assert(is.null(artifact$model$Ttrain) && is.null(artifact$model$Yfit),
         paste("Patient-level diagnostic arrays remain in:", path))
  assert(identical(artifact$model$diagnostics$solver, "rsvd") &&
           identical(artifact$model$diagnostics$rsvd$oversample,
                     cfg$analysis$rsvd_oversample) &&
           identical(artifact$model$diagnostics$rsvd$power,
                     cfg$analysis$rsvd_power) &&
           identical(artifact$model$diagnostics$rsvd$seed,
                     artifact$fit_seed),
         paste("Artifact was not fitted with the prespecified rSVD controls:", path))
  assert(length(artifact$feature_names) == cfg$analysis$expected_features,
         paste("Feature schema length mismatch:", path))
  assert(isFALSE(artifact$deployment_metadata$contains_patient_level_training_rows),
         paste("Artifact deployment metadata is inconsistent:", path))
  assert(identical(artifact$endpoint_transform, registry$endpoint_transform[i]) &&
           identical(artifact$output_units, registry$output_units[i]),
         paste("Artifact transformation/output metadata mismatch:", path))
  assert(identical(artifact$fastPLS_version, registry$fastPLS_version[i]) &&
           identical(artifact$fastPLS_remote_sha,
                     registry$fastPLS_remote_sha[i]) &&
           identical(artifact$backend, registry$backend[i]) &&
           identical(artifact$svd_method, registry$svd_method[i]) &&
           identical(artifact$rsvd_oversample,
                     registry$rsvd_oversample[i]) &&
           identical(artifact$rsvd_power, registry$rsvd_power[i]) &&
           identical(artifact$fit_seed, registry$fit_seed[i]),
         paste("Artifact software/backend metadata mismatch:", path))
  assert(identical(artifact$analysis_fingerprint,
                   registry$analysis_fingerprint[i]),
         paste("Artifact analysis fingerprint mismatch:", path))
  assert(identical(artifact$deployment_metadata$calibration_status,
                   registry$calibration_status[i]) &&
           identical(artifact$intended_use, registry$intended_use[i]),
         paste("Artifact calibration/intended-use metadata mismatch:", path))
}

audit_repeated_predictions <- function(path, jobs, label) {
  z <- fread(path)
  assert(uniqueN(z, by = c(key, "repeat", "patient")) == nrow(z),
         paste(label, "contains duplicate patient-repeat predictions"))
  counts <- z[, .(patients = uniqueN(patient), repeats = uniqueN(`repeat`),
                  rows = .N), by = key]
  expected <- jobs[, c(key, "n"), with = FALSE]
  counts <- merge(expected, counts, by = key, all = TRUE)
  assert(!anyNA(counts), paste(label, "endpoint coverage mismatch"))
  assert(all(counts$patients == counts$n &
               counts$repeats == cfg$analysis$robustness_repeats &
               counts$rows == counts$n * cfg$analysis$robustness_repeats),
         paste(label, "does not contain five complete patient-level repeats"))
}
audit_repeated_predictions(
  "results/predictions/continuous_repeated_oof_predictions.csv.gz",
  supported_c, "continuous repeated OOF"
)
continuous_oof <- fread(
  "results/predictions/continuous_repeated_oof_predictions.csv.gz"
)
continuous_fold_variation <- continuous_oof[, .(
  unique_predictions = uniqueN(signif(predicted, 12L))
), by = c(key, "repeat", "outer_fold")]
assert(all(continuous_fold_variation$unique_predictions > 1L),
       "A continuous held-out fold contains a recycled scalar prediction")
continuous_recomputed <- continuous_oof[, .(
  q2 = q_squared(observed, predicted),
  rmse = sqrt(mean((observed - predicted)^2)),
  spearman = suppressWarnings(cor(observed, predicted, method = "spearman"))
), by = c(key, "repeat")]
continuous_summary <- fread("results/tables/continuous_repeated_nested_cv.csv")
continuous_check <- merge(
  continuous_summary, continuous_recomputed,
  by = c(key, "repeat"), suffixes = c("_stored", "_recomputed")
)
assert(nrow(continuous_check) == nrow(continuous_summary) &&
         all(abs(continuous_check$q2_stored - continuous_check$q2_recomputed) < 1e-12) &&
         all(abs(continuous_check$rmse_stored - continuous_check$rmse_recomputed) < 1e-9) &&
         all(abs(continuous_check$spearman_stored - continuous_check$spearman_recomputed) < 1e-12),
       "Stored continuous repeated-CV metrics do not reproduce the OOF predictions")
audit_repeated_predictions(
  "results/predictions/binary_repeated_oof_predictions.csv.gz",
  supported_b, "binary repeated OOF"
)

for (item in list(
  list(file = "results/tables/continuous_site_grouped_sensitivity.csv",
       jobs = supported_c, label = "continuous site sensitivity"),
  list(file = "results/tables/binary_site_grouped_sensitivity.csv",
       jobs = supported_b, label = "binary site sensitivity"),
  list(file = "results/tables/continuous_slide_pooling_sensitivity.csv",
       jobs = supported_c, label = "continuous pooling sensitivity"),
  list(file = "results/tables/binary_slide_pooling_sensitivity.csv",
       jobs = supported_b, label = "binary pooling sensitivity")
)) {
  z <- fread(item$file)
  assert(uniqueN(z, by = key) == nrow(z), paste(item$label, "has duplicate keys"))
  assert("backend" %in% names(z) && all(!is.na(z$backend) & nzchar(z$backend)),
         paste(item$label, "has incomplete backend metadata"))
  assert("seed" %in% names(z) && all(is.finite(z$seed)),
         paste(item$label, "has incomplete rSVD seed metadata"))
  assert("svd_method" %in% names(z) &&
           all(z$svd_method == cfg$analysis$svd_method) &&
           all(z$rsvd_oversample == cfg$analysis$rsvd_oversample) &&
           all(z$rsvd_power == cfg$analysis$rsvd_power),
         paste(item$label, "does not record the prespecified rSVD configuration"))
  if (grepl("site sensitivity$", item$label)) {
    feasible <- z$feasible %in% TRUE
    assert(all(z$maximum_outer_folds_per_site[feasible] == 1L &
                 !z$outer_site_overlap[feasible]),
           paste(item$label, "contains tissue-source-site leakage"))
  }
  assert(nrow(z) == nrow(item$jobs) &&
           nrow(fsetdiff(z[, ..key], item$jobs[, ..key])) == 0L,
         paste(item$label, "does not cover every screen-positive endpoint"))
}

site_fold_detail <- fread("results/tables/site_grouped_outer_fold_composition.csv")
site_fold_summary <- fread("results/tables/site_grouped_fold_composition_summary.csv")
assert(nrow(site_fold_detail) == 1613L && nrow(site_fold_summary) == nrow(registry),
       "Tissue-source-site fold-composition coverage is incomplete")
assert(!any(site_fold_detail$inner_site_overlap) &
         all(site_fold_detail$maximum_inner_folds_per_site == 1L) &
         all(site_fold_summary$inner_site_grouped),
       "At least one inner component-selection split divides a tissue-source site")
assert(all(site_fold_detail$test_patients > 0L &
             site_fold_detail$test_sites > 0L &
             site_fold_detail$training_patients > 0L &
             site_fold_detail$training_sites > 0L),
       "Site-grouped fold composition contains an empty partition")

site_prediction <- fread("results/tables/tissue_source_site_predictability_summary.csv")
site_prediction_repeats <- fread("results/tables/tissue_source_site_predictability_repeats.csv")
site_prediction_ok <- site_prediction[eligible == TRUE & (is.na(error) | !nzchar(error))]
assert(nrow(site_prediction) == 32L && nrow(site_prediction_ok) == 27L &&
         nrow(site_prediction_repeats) == 27L * 5L,
       "Within-cancer tissue-source-site predictability coverage is incomplete")
assert(all(site_prediction_ok$analysed_sites >= 2L &
             site_prediction_ok$minimum_patients_per_site == 10L &
             site_prediction_ok$macro_balanced_accuracy_mean >
               site_prediction_ok$chance_macro_balanced_accuracy &
             is.finite(site_prediction_ok$normalized_macro_balanced_accuracy)),
       "Within-cancer tissue-source-site metrics are incomplete or inconsistent")

pls_comparison <- fread(
  "results/tables/pls1_vs_pls2_inflammation_by_repeat.csv"
)
pls_key <- c("tumor_type", "block", "endpoint")
assert(all(!is.na(pls_comparison$backend) & nzchar(pls_comparison$backend)),
       "PLS1–PLS2 comparison has incomplete backend metadata")
assert(all(pls_comparison$svd_method == cfg$analysis$svd_method &
             pls_comparison$rsvd_oversample == cfg$analysis$rsvd_oversample &
             pls_comparison$rsvd_power == cfg$analysis$rsvd_power),
       "PLS1–PLS2 comparison does not record the prespecified rSVD configuration")
assert("analysis_fingerprint" %in% names(pls_comparison) &&
         all(!is.na(pls_comparison$analysis_fingerprint) &
               nzchar(pls_comparison$analysis_fingerprint)) &&
         uniqueN(pls_comparison$analysis_fingerprint) == 1L,
       "PLS1–PLS2 comparison has inconsistent analysis fingerprints")
pls_repeat_counts <- pls_comparison[, .(
  repeats = uniqueN(repeat_id), rows = .N
), by = pls_key]
assert(all(pls_repeat_counts$repeats == 3L & pls_repeat_counts$rows == 3L),
       "PLS1–PLS2 comparison does not have three complete matched repeats")

highlighted <- fread("results/tables/highlighted_model_performance.csv")
assert(nrow(highlighted) <= 24L && nrow(highlighted) > 0L,
       "Highlighted-model table has an unexpected size")
assert(all(highlighted$model_fastPLS_version == "0.99.20" &
             startsWith(highlighted$model_fastPLS_remote_sha, "dcf45cc") &
             !is.na(highlighted$model_backend) &
             nzchar(highlighted$model_backend) &
             highlighted$model_svd_method == cfg$analysis$svd_method &
             highlighted$model_rsvd_oversample == cfg$analysis$rsvd_oversample &
             highlighted$model_rsvd_power == cfg$analysis$rsvd_power &
             is.finite(highlighted$model_fit_seed)),
       "Highlighted-model software/backend metadata are incomplete")
assert(all(highlighted$model_analysis_fingerprint ==
             registry$analysis_fingerprint[1L]),
       "Highlighted-model analysis fingerprints are missing or inconsistent")
assert(all(!is.na(highlighted$model_sha256) & nzchar(highlighted$model_sha256) &
             !is.na(highlighted$feature_schema_sha256) &
             nzchar(highlighted$feature_schema_sha256) &
             !is.na(highlighted$titan_feature_file_sha256) &
             nzchar(highlighted$titan_feature_file_sha256)),
       "Highlighted-model checksum metadata are incomplete")
binary_h <- highlighted[outcome_type == "binary"]
continuous_h <- highlighted[outcome_type == "continuous"]
assert(all(is.finite(binary_h$sensitivity) & is.finite(binary_h$specificity) &
             is.finite(binary_h$balanced_accuracy) & is.finite(binary_h$auc)),
       "Highlighted binary metrics are incomplete")
assert(all(is.finite(continuous_h$q2) & is.finite(continuous_h$rmse) &
             is.finite(continuous_h$spearman)),
       "Highlighted continuous metrics are incomplete")
binary_ci <- c("sensitivity_ci_low", "sensitivity_ci_high",
               "specificity_ci_low", "specificity_ci_high",
               "balanced_accuracy_ci_low", "balanced_accuracy_ci_high",
               "auc_ci_low", "auc_ci_high")
continuous_ci <- c("q2_ci_low", "q2_ci_high", "rmse_ci_low", "rmse_ci_high",
                   "spearman_ci_low", "spearman_ci_high")
assert(all(vapply(binary_h[, ..binary_ci], function(x) all(is.finite(x)),
                  logical(1))),
       "Highlighted binary uncertainty intervals are incomplete")
assert(all(vapply(continuous_h[, ..continuous_ci],
                  function(x) all(is.finite(x)), logical(1))),
       "Highlighted continuous uncertainty intervals are incomplete")

site_retention <- fread("results/tables/site_grouped_retention_summary.csv")
combined_retention <- site_retention[outcome_type == "combined"]
assert(nrow(combined_retention) == 1L &&
         combined_retention$screen_positive_models == nrow(supported) &&
         combined_retention$below_threshold_models == 83L &&
         abs(combined_retention$below_threshold_percent - 100 * 83 / 323) < 1e-10,
       "Site-grouped threshold-retention summary is inconsistent")

mutation_audit <- fread("results/tables/supported_mutation_literature_audit.csv")
evidence_counts <- mutation_audit[, .N, by = evidence_class]
assert(nrow(mutation_audit) == 41L &&
         evidence_counts[
           evidence_class == "previously supported in reviewed predictive literature", N
         ] == 38L &&
         evidence_counts[
           evidence_class == "previously evaluated without statistical support in reviewed study", N
         ] == 2L &&
         evidence_counts[
           evidence_class == "not identified in reviewed predictive literature", N
         ] == 1L,
       "Expanded mutation-literature evidence counts are inconsistent")

ridge_comparison <- fread("results/tables/pls_vs_ridge_highlighted_models.csv")
binary_symmetric <- fread(
  "results/tables/binary_symmetric_pls_ridge_repeated_nested_cv.csv"
)
assert(nrow(ridge_comparison) == nrow(highlighted) &&
         all(ridge_comparison$repeats == cfg$analysis$robustness_repeats) &&
         all(is.finite(ridge_comparison$delta_ridge_minus_pls)) &&
         all(is.finite(ridge_comparison$delta_secondary_ridge_minus_pls)) &&
         all(ridge_comparison[outcome_type == "binary", primary_metric] ==
               "AUROC (threshold-independent)") &&
         all(ridge_comparison[outcome_type == "binary", secondary_metric] ==
               "balanced accuracy (inner-CV thresholds for both)") &&
         all(ridge_comparison$benchmark_scope == paste(
           "24 manuscript-highlighted PLS screen-positive models; conditional symmetric",
           "benchmark not suitable for claiming atlas-wide PLS superiority"
         )),
       "Exportable ridge benchmark is incomplete or mis-scoped")
assert(nrow(binary_symmetric) ==
         12L * cfg$analysis$robustness_repeats &&
         all(binary_symmetric$outer_folds_identical) &&
         all(binary_symmetric$inner_folds_identical) &&
         all(binary_symmetric$threshold_selection == paste(
           "identical inner-CV rule for both methods:",
           "maximise balanced accuracy on inner out-of-fold scores"
         )) &&
         all(is.finite(binary_symmetric$pls_auc)) &&
         all(is.finite(binary_symmetric$ridge_auc)) &&
         all(is.finite(binary_symmetric$pls_balanced_accuracy)) &&
         all(is.finite(binary_symmetric$ridge_balanced_accuracy)),
       "Symmetric binary PLS-ridge benchmark is incomplete")

cohort <- fread("results/tables/patient_cohort_summary.csv")
assert(nrow(cohort) == 9404L && sum(cohort$n_slides) == 11449L,
       "Patient/slide cohort totals changed unexpectedly")
assert(sum(cohort$n_slides > 1L) == 843L,
       "Multiple-slide patient total changed unexpectedly")
characteristics <- fread("results/tables/participant_characteristics_by_cancer.csv")
overall <- characteristics[tumor_type == "Overall"]
assert(nrow(overall) == 1L && overall$patients == 9404L &&
         overall$cdr_matched == 9385L,
       "Participant-characteristic coverage is inconsistent")

software <- fread("results/tables/software_manifest.csv")
fastpls_software <- software[package == "fastPLS"]
tcga_software <- software[package == "TCGAmutations"]
assert(nrow(fastpls_software) == 1L && fastpls_software$installed &&
         fastpls_software$version == "0.99.20" &&
         startsWith(fastpls_software$installed_remote_sha, "dcf45cc") &&
         grepl("dcf45cccee8a1cb1a3ae8b3353a410ab0902162f$",
               fastpls_software$configured_source),
       "Software manifest does not identify the pinned fastPLS build")
assert(nrow(tcga_software) == 1L && tcga_software$installed &&
         tcga_software$version == "0.4.0" &&
         grepl("3474e3412cfa1490db4a84db57e4a732480990a9$",
               tcga_software$configured_source),
       "Software manifest does not identify the pinned TCGAmutations source")

figures <- c(
  "Figure1_patient_first_workflow.png", "Figure2_continuous_atlas.png",
  "Figure3_binary_atlas.png", "Figure4_prediction_examples.png",
  "Figure5_supported_counts.png", "Figure6_site_grouped_sensitivity.png",
  "Figure6a_pls1_vs_pls2_targets.png", "Figure6b_pls1_vs_pls2_cancers.png"
)
assert(all(file.exists(file.path("figures", figures))), "A required figure is missing")

cat("Release audit passed:", nrow(continuous), "continuous tests;",
    nrow(binary), "binary tests;", nrow(registry), "saved research models\n")
