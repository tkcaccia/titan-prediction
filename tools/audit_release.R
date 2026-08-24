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

uncertainty <- fread("results/tables/permutation_monte_carlo_uncertainty.csv")
assert(nrow(uncertainty) == nrow(continuous) + nrow(binary) &&
         uniqueN(uncertainty, by = c("outcome_type", key)) == nrow(uncertainty),
       "Permutation Monte Carlo uncertainty table has incomplete or duplicate keys")
screen_uncertainty <- rbindlist(list(
  continuous[, .(
    outcome_type = "continuous", family, tumor_type, endpoint,
    p_permutation, permutations, permutation_exceedances,
    permutation_attempted, permutation_stopped_early
  )],
  binary[, .(
    outcome_type = "binary", family, tumor_type, endpoint,
    p_permutation, permutations, permutation_exceedances,
    permutation_attempted, permutation_stopped_early
  )]
))
setkeyv(uncertainty, c("outcome_type", key))
setkeyv(screen_uncertainty, c("outcome_type", key))
assert(nrow(fsetdiff(
  uncertainty[, names(screen_uncertainty), with = FALSE], screen_uncertainty
)) == 0L && nrow(fsetdiff(
  screen_uncertainty, uncertainty[, names(screen_uncertainty), with = FALSE]
)) == 0L, "Monte Carlo table does not reproduce screen permutation metadata")
completed_uncertainty <- uncertainty[
  permutations > 0L & !permutation_stopped_early
]
mc_expected <- t(vapply(seq_len(nrow(completed_uncertainty)), function(i) {
  b <- completed_uncertainty$permutation_exceedances[[i]]
  B <- completed_uncertainty$permutations[[i]]
  c(
    lower = if (b == 0L) 0 else qbeta(0.025, b, B - b + 1L),
    upper = if (b == B) 1 else qbeta(0.975, b + 1L, B - b)
  )
}, numeric(2L)))
assert(all(abs(completed_uncertainty$p_mc_lower_95 - mc_expected[, "lower"]) < 1e-12) &&
         all(abs(completed_uncertainty$p_mc_upper_95 - mc_expected[, "upper"]) < 1e-12),
       "Monte Carlo intervals do not reproduce exact Clopper-Pearson bounds")
zero_999 <- completed_uncertainty[
  permutations == 999L & permutation_exceedances == 0L
]
assert(nrow(zero_999) > 0L && all(zero_999$p_mc_lower_95 == 0) &&
         all(abs(zero_999$p_mc_upper_95 - 0.00368576286573938) < 1e-12),
       "Zero-exceedance 999-permutation Monte Carlo bounds are incorrect")

multiplicity <- fread("results/tables/multiplicity_sensitivity_by_endpoint.csv")
assert(nrow(multiplicity) == nrow(continuous) + nrow(binary) &&
         uniqueN(multiplicity, by = c("outcome_type", key)) == nrow(multiplicity),
       "Atlas-wide multiplicity table has incomplete or duplicate keys")
screen_multiplicity <- rbindlist(list(
  continuous[, .(
    outcome_type = "continuous", family, tumor_type, endpoint,
    p_permutation, q_value, q_value_global, tier
  )],
  binary[, .(
    outcome_type = "binary", family, tumor_type, endpoint,
    p_permutation, q_value, q_value_global, tier
  )]
))
shared_multiplicity_columns <- names(screen_multiplicity)
assert(nrow(fsetdiff(
  multiplicity[, ..shared_multiplicity_columns], screen_multiplicity
)) == 0L && nrow(fsetdiff(
  screen_multiplicity, multiplicity[, ..shared_multiplicity_columns]
)) == 0L, "Multiplicity sensitivity table does not reproduce primary screen fields")
setorder(multiplicity, outcome_type, family, tumor_type, endpoint)
expected_atlas_q <- p.adjust(multiplicity$p_permutation, method = "BH")
assert(all(abs(multiplicity$q_value_atlas_wide - expected_atlas_q) < 1e-12),
       "Atlas-wide q values do not reproduce BH across all eligible tests")
expected_outcome_q <- multiplicity[, .(
  expected = p.adjust(p_permutation, method = "BH")
), by = outcome_type]$expected
assert(all(abs(multiplicity$q_value_outcome_wide - expected_outcome_q) < 1e-12),
       "Outcome-wide q values do not reproduce BH within outcome type")
expected_multiplicity_summary <- rbindlist(lapply(
  c("continuous", "binary"), function(kind) {
    z <- multiplicity[outcome_type == kind]
    primary <- if (kind == "continuous") continuous else binary
    effect_ok <- if (kind == "continuous") {
      is.finite(primary$q2) & primary$q2 >= cfg$analysis$continuous_effect_gate
    } else {
      is.finite(primary$adjusted_balanced_accuracy) &
        primary$adjusted_balanced_accuracy >= cfg$analysis$binary_adjusted_ba_gate
    }
    local <- z$tier %chin% c("A", "B")
    data.table(
      outcome_type = kind,
      eligible_tests = nrow(z),
      effect_eligible = sum(effect_ok),
      within_cancer_family_candidates = sum(local),
      across_cancer_family_pass = sum(local & z$q_value_global < 0.05),
      outcome_wide_pass = sum(local & z$q_value_outcome_wide < 0.05),
      atlas_wide_pass = sum(local & z$q_value_atlas_wide < 0.05)
    )
  }
))
expected_multiplicity_summary <- rbind(
  expected_multiplicity_summary,
  as.data.table(c(
    list(outcome_type = "combined"),
    lapply(expected_multiplicity_summary[, -"outcome_type"], sum)
  ))
)
reported_multiplicity_summary <- fread(
  "results/tables/multiplicity_sensitivity_summary.csv"
)
assert(nrow(fsetdiff(expected_multiplicity_summary,
                     reported_multiplicity_summary)) == 0L &&
         nrow(fsetdiff(reported_multiplicity_summary,
                       expected_multiplicity_summary)) == 0L,
       "Multiplicity sensitivity summary does not reproduce endpoint-level counts")

target_registry <- fread(
  "data/reference/targeted_permutation_refinement_targets.csv"
)
targeted <- fread("results/tables/targeted_permutation_refinement.csv")
assert(nrow(targeted) == nrow(target_registry) &&
         nrow(fsetdiff(targeted[, c("outcome_type", key), with = FALSE],
                       target_registry[, c("outcome_type", key), with = FALSE])) == 0L &&
         nrow(fsetdiff(target_registry[, c("outcome_type", key), with = FALSE],
                       targeted[, c("outcome_type", key), with = FALSE])) == 0L,
       "Targeted 9,999-permutation result keys do not match the locked registry")
assert(all(targeted$refined_permutations >= 9999L) &&
         all(!targeted$refinement_stopped_early) &&
         all(abs(targeted$refined_p_9999 -
                   (targeted$refined_exceedances_9999 + 1) /
                   (targeted$refined_permutations + 1)) < 1e-12),
       "Targeted refinement p values or permutation counts are invalid")
targeted_mc <- t(vapply(seq_len(nrow(targeted)), function(i) {
  b <- targeted$refined_exceedances_9999[[i]]
  B <- targeted$refined_permutations[[i]]
  c(
    lower = if (b == 0L) 0 else qbeta(0.025, b, B - b + 1L),
    upper = if (b == B) 1 else qbeta(0.975, b + 1L, B - b)
  )
}, numeric(2L)))
assert(all(abs(targeted$refined_mc_lower_95 - targeted_mc[, "lower"]) < 1e-12) &&
         all(abs(targeted$refined_mc_upper_95 - targeted_mc[, "upper"]) < 1e-12) &&
         all(targeted$full_nested_process_repeated) &&
         all(targeted$scaling_relearned_within_folds) &&
         all(targeted$inner_component_selection_repeated) &&
         all(targeted$outer_predictions_regenerated) &&
         all(targeted$fastPLS_version == as.character(packageVersion("fastPLS"))) &&
         all(targeted$pls_method == "simpls") &&
         all(targeted$scaling == "centering") &&
         all(targeted$target_registry_git_commit == "ac30ccb") &&
         all(targeted$svd_method == cfg$analysis$svd_method) &&
         all(targeted$rsvd_oversample == cfg$analysis$rsvd_oversample) &&
         all(targeted$rsvd_power == cfg$analysis$rsvd_power),
       "Targeted refinement uncertainty or full-process metadata are invalid")

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
binary_reliability_registry_fields <- c(
  "model_evidence_tier", "default_inference", "limited_evidence_reason",
  "binary_pr_auc", "binary_ppv_tcga_prevalence",
  "binary_npv_tcga_prevalence", "binary_observed_tcga_prevalence",
  "binary_minimum_outer_test_positive", "binary_minimum_outer_test_negative",
  "binary_minimum_inner_training_positive",
  "binary_minimum_inner_training_negative",
  "binary_selected_components_median", "binary_selected_components_q1",
  "binary_selected_components_q3", "binary_selected_components_minimum",
  "binary_selected_components_maximum", "binary_repeat_score_spearman",
  "binary_repeat_class_agreement", "binary_all_repeat_class_agreement"
)
assert(all(binary_reliability_registry_fields %chin% names(registry)),
       "Model registry lacks binary class-reliability metadata")
assert(sum(binary_registry$model_evidence_tier ==
             "exploratory_limited_evidence") == 17L &&
         sum(binary_registry$default_inference) == 87L &&
         all(binary_registry$default_inference ==
               (binary_registry$positive >= 50L &
                  binary_registry$negative >= 50L)) &&
         all(nzchar(binary_registry$limited_evidence_reason[
           !binary_registry$default_inference
         ])) &&
         all(is.finite(binary_registry$binary_pr_auc) &
               is.finite(binary_registry$binary_ppv_tcga_prevalence) &
               is.finite(binary_registry$binary_npv_tcga_prevalence) &
               is.finite(binary_registry$binary_repeat_score_spearman) &
               is.finite(binary_registry$binary_repeat_class_agreement)),
       "Binary registry evidence tiers or reliability metrics are invalid")
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

binary_reliability <- fread(
  "results/tables/binary_class_reliability_summary.csv"
)
binary_reliability_repeats <- fread(
  "results/tables/binary_reliability_by_repeat.csv"
)
binary_fold_counts <- fread(
  "results/tables/binary_outer_fold_class_counts.csv"
)
binary_components <- fread(
  "results/tables/binary_selected_components_by_fold.csv"
)
binary_component_summary <- fread(
  "results/tables/binary_selected_component_distribution.csv"
)
binary_minimum_sensitivity <- fread(
  "results/tables/binary_minimum_class_sensitivity.csv"
)
binary_learning_repeats <- fread(
  "results/tables/binary_limited_evidence_learning_curve_repeats.csv"
)
binary_learning_folds <- fread(
  "results/tables/binary_limited_evidence_learning_curve_folds.csv"
)
binary_learning_summary <- fread(
  "results/tables/binary_limited_evidence_learning_curve_summary.csv"
)
assert(nrow(binary_reliability) == 104L &&
         nrow(binary_reliability_repeats) == 520L &&
         nrow(binary_fold_counts) == 2600L &&
         nrow(binary_components) == 2600L &&
         nrow(binary_component_summary) == 104L,
       "Binary reliability coverage is incomplete")
assert(binary_minimum_sensitivity[
         minimum_per_class == 20L, eligible_binary_targets] == 459L &&
         binary_minimum_sensitivity[
           minimum_per_class == 50L, eligible_binary_targets] == 244L &&
         binary_minimum_sensitivity[
           minimum_per_class == 20L, screen_positive_binary_models] == 104L &&
         binary_minimum_sensitivity[
           minimum_per_class == 50L, screen_positive_binary_models] == 87L,
       "The 50-per-class sensitivity counts are inconsistent")
assert(all(binary_fold_counts$training_positive > 0L &
             binary_fold_counts$training_negative > 0L &
             binary_fold_counts$test_positive > 0L &
             binary_fold_counts$test_negative > 0L) &&
         all(binary_fold_counts$training_positive +
               binary_fold_counts$test_positive ==
               binary_fold_counts$positive) &&
         all(binary_fold_counts$training_negative +
               binary_fold_counts$test_negative ==
               binary_fold_counts$negative),
       "Binary repeated outer-fold class counts are invalid")
component_fold_check <- merge(
  binary_components,
  binary_fold_counts[, .(
    family, tumor_type, endpoint, `repeat`, outer_fold,
    training_positive, training_negative, test_positive, test_negative
  )],
  by = c(key, "repeat", "outer_fold"), all = TRUE
)
assert(nrow(component_fold_check) == 2600L &&
         all(component_fold_check$selected_components %in%
               cfg$analysis$components) &&
         all(component_fold_check$outer_training_positive ==
               component_fold_check$training_positive) &&
         all(component_fold_check$outer_training_negative ==
               component_fold_check$training_negative) &&
         all(component_fold_check$outer_test_positive ==
               component_fold_check$test_positive) &&
         all(component_fold_check$outer_test_negative ==
               component_fold_check$test_negative) &&
         all(component_fold_check$minimum_inner_training_positive > 0L) &&
         all(component_fold_check$minimum_inner_training_negative > 0L) &&
         all(component_fold_check$minimum_inner_validation_positive > 0L) &&
         all(component_fold_check$minimum_inner_validation_negative > 0L),
       "Binary component-selection or inner-fold class audit is invalid")
assert(nrow(binary_learning_repeats) == 255L &&
         nrow(binary_learning_folds) == 1275L &&
         nrow(binary_learning_summary) == 51L &&
         all(sort(unique(binary_learning_summary$training_fraction)) ==
               c(0.50, 0.75, 1.00)),
       "Limited-evidence learning-curve coverage is incomplete")
learning_full <- binary_learning_repeats[training_fraction == 1]
reliability_limited <- binary_reliability_repeats[
  binary_reliability[model_evidence_tier ==
    "exploratory_limited_evidence", ..key], on = key, nomatch = 0L
]
learning_check <- merge(
  learning_full, reliability_limited,
  by = c(key, "repeat"), suffixes = c("_learning", "_original")
)
assert(nrow(learning_check) == 85L &&
         all(abs(learning_check$balanced_accuracy_learning -
                   learning_check$balanced_accuracy_original) < 1e-12) &&
         all(abs(learning_check$auc_learning -
                   learning_check$auc_original) < 1e-12) &&
         all(abs(learning_check$pr_auc_learning -
                   learning_check$pr_auc_original) < 1e-12),
       "Full-data learning-curve fits do not reproduce repeated-CV metrics")
highlighted_reliability <- fread(
  "results/tables/highlighted_model_performance.csv"
)[outcome_type == "binary"]
assert(nrow(highlighted_reliability) == 12L &&
         all(highlighted_reliability$default_inference) &&
         all(highlighted_reliability$model_evidence_tier ==
               "standard_internal_evidence") &&
         all(is.finite(highlighted_reliability$pr_auc) &
               is.finite(highlighted_reliability$ppv_tcga_prevalence) &
               is.finite(highlighted_reliability$npv_tcga_prevalence)),
       "Headline binary models lack standard evidence or required metrics")

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
assert(all(highlighted$uncertainty_interval_label == paste(
         "95% selection-conditioned patient-resampling interval for repeated",
         "out-of-fold predictions"
       )) &&
         all(highlighted$uncertainty_resamples == 1000L) &&
         all(highlighted$uncertainty_repeat_partitions ==
               cfg$analysis$robustness_repeats) &&
         all(highlighted$uncertainty_selection_conditioned) &&
         all(grepl("without refitting", highlighted$uncertainty_method,
                   fixed = TRUE)) &&
         all(grepl("initial atlas screening and endpoint selection",
                   highlighted$uncertainty_excluded, fixed = TRUE)),
       "Highlighted uncertainty is not explicitly selection-conditioned")

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

ridge_comparison <- fread(
  "results/tables/pls_vs_ridge_representative_models.csv"
)
ridge_jobs <- fread("results/tables/pls_vs_ridge_representative_jobs.csv")
ridge_sampling_frame <- fread(
  "results/tables/pls_vs_ridge_representative_sampling_frame.csv"
)
ridge_stratified_summary <- fread(
  "results/tables/pls_vs_ridge_representative_stratified_summary.csv"
)
ridge_repeat_models <- fread(
  "results/tables/pls_vs_ridge_representative_repeated_nested_cv.csv"
)
binary_symmetric <- fread(
  paste0(
    "results/tables/",
    "binary_symmetric_pls_ridge_representative_repeated_nested_cv.csv"
  )
)
ridge_paired_repeats <- fread(
  paste0(
    "results/tables/",
    "pls_vs_ridge_representative_paired_repeat_metrics.csv"
  )
)
ridge_matched_predictions <- fread(
  paste0(
    "results/predictions/",
    "pls_vs_ridge_representative_matched_oof_predictions.csv.gz"
  )
)
ridge_selected_keys <- ridge_sampling_frame[selected == TRUE, .(
  outcome_type, family, tumor_type, endpoint
)]
ridge_comparison_keys <- ridge_comparison[, .(
  outcome_type, family, tumor_type, endpoint
)]
ridge_nonempty_continuous_cells <- unique(
  ridge_sampling_frame[outcome_type == "continuous", .(
    family, size_stratum
  )]
)
ridge_nonempty_binary_cells <- unique(
  ridge_sampling_frame[outcome_type == "binary", .(
    family, size_stratum, imbalance_stratum
  )]
)
assert(nrow(ridge_sampling_frame) == nrow(continuous) + nrow(binary) &&
         nrow(ridge_jobs) == 47L && nrow(ridge_comparison) == 47L &&
         nrow(ridge_comparison[outcome_type == "continuous"]) == 12L &&
         nrow(ridge_comparison[outcome_type == "binary"]) == 35L &&
         nrow(ridge_nonempty_continuous_cells) == 12L &&
         nrow(ridge_nonempty_binary_cells) == 35L &&
         all(!ridge_sampling_frame$selection_uses_pls_performance) &&
         all(!ridge_jobs$selection_uses_pls_performance) &&
         nrow(ridge_selected_keys) == 47L &&
         nrow(fsetdiff(ridge_selected_keys, ridge_comparison_keys)) == 0L &&
         nrow(fsetdiff(ridge_comparison_keys, ridge_selected_keys)) == 0L &&
         uniqueN(ridge_sampling_frame$selection_hash) ==
           nrow(ridge_sampling_frame) &&
         unique(ridge_sampling_frame$selection_version) ==
           "titan-representative-benchmark-v1" &&
         all(c("outcome family", "sample size", "class imbalance") %in%
               ridge_stratified_summary$stratifier),
       "Representative PLS-ridge sampling is incomplete or performance-selected")
assert(
         all(ridge_comparison$repeats == cfg$analysis$robustness_repeats) &&
         all(is.finite(ridge_comparison$delta_ridge_minus_pls)) &&
         all(is.finite(ridge_comparison$delta_secondary_ridge_minus_pls)) &&
         all(is.finite(ridge_comparison$delta_ci_low)) &&
         all(is.finite(ridge_comparison$delta_ci_high)) &&
         all(is.finite(ridge_comparison$delta_secondary_ci_low)) &&
         all(is.finite(ridge_comparison$delta_secondary_ci_high)) &&
         all(ridge_comparison$bootstrap_resamples == 2000L) &&
         all(ridge_comparison$bootstrap_unit == "patient cluster") &&
         all(ridge_comparison$interval_method == paste(
           "selection-conditioned paired patient-resampling percentile interval",
           "for the ridge-minus-PLS difference in the mean of five",
           "repeat-specific out-of-fold metrics"
         )) &&
         all(grepl("model refitting within bootstrap replicates",
                   ridge_comparison$uncertainty_excluded, fixed = TRUE)) &&
         !("delta_se" %in% names(ridge_comparison)) &&
         !("delta_secondary_se" %in% names(ridge_comparison)) &&
         all(ridge_comparison[outcome_type == "binary", primary_metric] ==
               "AUROC (threshold-independent)") &&
         all(ridge_comparison[outcome_type == "binary", secondary_metric] ==
               "balanced accuracy (inner-CV thresholds for both)") &&
         all(ridge_comparison$benchmark_scope == paste(
           "47 metadata-stratified endpoints selected from all 2073 eligible tests",
           "without reference to PLS performance; representative rather than atlas-wide"
         )),
       "Exportable ridge benchmark is incomplete or mis-scoped")
ridge_key <- c("outcome_type", "family", "tumor_type", "endpoint")
ridge_repeat_counts <- ridge_paired_repeats[, .(
  repeats = uniqueN(repeat_id), rows = .N
), by = ridge_key]
ridge_prediction_counts <- ridge_matched_predictions[, .(
  repeats = uniqueN(repeat_id), patients_per_repeat = .N / uniqueN(repeat_id),
  minimum_patient_repeats = min(table(patient)),
  maximum_patient_repeats = max(table(patient))
), by = ridge_key]
assert(nrow(ridge_paired_repeats) ==
         nrow(ridge_comparison) * cfg$analysis$robustness_repeats &&
         all(ridge_repeat_counts$repeats == cfg$analysis$robustness_repeats) &&
         all(ridge_repeat_counts$rows == cfg$analysis$robustness_repeats) &&
         nrow(ridge_prediction_counts) == nrow(ridge_comparison) &&
         all(ridge_prediction_counts$repeats ==
               cfg$analysis$robustness_repeats) &&
         all(ridge_prediction_counts$minimum_patient_repeats ==
               cfg$analysis$robustness_repeats) &&
         all(ridge_prediction_counts$maximum_patient_repeats ==
               cfg$analysis$robustness_repeats) &&
         all(is.finite(ridge_matched_predictions$pls_prediction)) &&
         all(is.finite(ridge_matched_predictions$ridge_prediction)) &&
         all(is.finite(
           ridge_matched_predictions[outcome_type == "binary", pls_score]
         )) &&
         all(is.finite(
           ridge_matched_predictions[outcome_type == "binary", ridge_score]
         )),
       "Paired patient-level PLS-ridge predictions or repeat metrics are incomplete")
ridge_point_check <- ridge_paired_repeats[, .(
  delta_ridge_minus_pls_check = mean(delta_ridge_minus_pls),
  delta_secondary_ridge_minus_pls_check =
    mean(delta_secondary_ridge_minus_pls)
), by = ridge_key]
ridge_point_check <- merge(
  ridge_comparison[, c(
    ridge_key, "delta_ridge_minus_pls",
    "delta_secondary_ridge_minus_pls"
  ), with = FALSE],
  ridge_point_check, by = ridge_key
)
assert(all(abs(ridge_point_check$delta_ridge_minus_pls -
                 ridge_point_check$delta_ridge_minus_pls_check) < 1e-12) &&
         all(abs(ridge_point_check$delta_secondary_ridge_minus_pls -
                 ridge_point_check$delta_secondary_ridge_minus_pls_check) <
               1e-12),
       "PLS-ridge point differences do not equal the mean paired-repeat differences")
assert(nrow(binary_symmetric) ==
         35L * cfg$analysis$robustness_repeats &&
         nrow(ridge_repeat_models) ==
           47L * cfg$analysis$robustness_repeats &&
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
continuous_symmetric <- ridge_repeat_models[outcome_type == "continuous"]
assert(nrow(continuous_symmetric) ==
         12L * cfg$analysis$robustness_repeats &&
         all(continuous_symmetric$outer_folds_identical) &&
         all(continuous_symmetric$inner_folds_identical) &&
         all(continuous_symmetric$tuning_rule_symmetry == paste(
           "identical outer and inner folds; both PLS component count and",
           "ridge penalty selected by maximising pooled inner out-of-fold Q2"
         )) &&
         all(is.finite(continuous_symmetric$pls_q2)) &&
         all(is.finite(continuous_symmetric$ridge_q2)),
       "Symmetric continuous PLS-ridge benchmark is incomplete")

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
