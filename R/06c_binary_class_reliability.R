.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
options(fastPLS.backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

key <- c("family", "tumor_type", "endpoint")
screen <- fread("results/tables/binary_screen.csv")
jobs <- screen[tier %chin% c("A", "B")]
jobs[, job_index := .I]
predictions <- fread(
  "results/predictions/binary_repeated_oof_predictions.csv.gz"
)
cohort <- readRDS("data/processed/patient_cohort.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)

average_precision <- function(truth, score) {
  truth <- as.integer(truth)
  keep <- truth %in% c(0L, 1L) & is.finite(score)
  truth <- truth[keep]
  score <- score[keep]
  n_positive <- sum(truth == 1L)
  if (!n_positive || !sum(truth == 0L)) return(NA_real_)
  by_score <- data.table(score = score, positive = truth == 1L)[, .(
    positives = sum(positive), total = .N
  ), by = score]
  setorder(by_score, -score)
  by_score[, `:=`(
    cumulative_positive = cumsum(positives),
    cumulative_total = cumsum(total)
  )]
  by_score[, precision := cumulative_positive / cumulative_total]
  sum((by_score$positives / n_positive) * by_score$precision)
}

binary_metrics_extended <- function(d) {
  truth <- as.integer(d$observed)
  estimate <- as.integer(d$predicted)
  tp <- sum(truth == 1L & estimate == 1L)
  fn <- sum(truth == 1L & estimate == 0L)
  tn <- sum(truth == 0L & estimate == 0L)
  fp <- sum(truth == 0L & estimate == 1L)
  sensitivity <- tp / (tp + fn)
  specificity <- tn / (tn + fp)
  data.table(
    sensitivity = sensitivity,
    specificity = specificity,
    balanced_accuracy = mean(c(sensitivity, specificity)),
    auc = rank_auc(truth, d$lda_score),
    pr_auc = average_precision(truth, d$lda_score),
    ppv_tcga_prevalence = if (tp + fp) tp / (tp + fp) else NA_real_,
    npv_tcga_prevalence = if (tn + fn) tn / (tn + fn) else NA_real_,
    observed_tcga_prevalence = mean(truth == 1L)
  )
}

repeat_metrics <- predictions[, binary_metrics_extended(.SD),
                              by = c(key, "repeat")]
setorder(repeat_metrics, family, tumor_type, endpoint, `repeat`)
fwrite(repeat_metrics,
       "results/tables/binary_reliability_by_repeat.csv")

fold_counts <- predictions[, .(
  test_patients = .N,
  test_positive = sum(observed == 1L),
  test_negative = sum(observed == 0L)
), by = c(key, "repeat", "outer_fold")]
totals <- jobs[, .(family, tumor_type, endpoint, n, positive, negative)]
fold_counts <- merge(fold_counts, totals, by = key, all.x = TRUE)
fold_counts[, `:=`(
  training_patients = n - test_patients,
  training_positive = positive - test_positive,
  training_negative = negative - test_negative,
  limited_evidence = pmin(positive, negative) < 50L
)]
setcolorder(fold_counts, c(
  key, "repeat", "outer_fold", "n", "positive", "negative",
  "training_patients", "training_positive", "training_negative",
  "test_patients", "test_positive", "test_negative", "limited_evidence"
))
setorder(fold_counts, family, tumor_type, endpoint, `repeat`, outer_fold)
fwrite(fold_counts,
       "results/tables/binary_outer_fold_class_counts.csv")

# Recreate the exact inner component-selection calls to recover information
# that was not stored by the original repeated-CV script. No endpoint is
# rescreened and no model tier is changed by this reconstruction.
component_checkpoint_dir <-
  "data/processed/checkpoints/binary_class_reliability/components"
dir.create(component_checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
component_fingerprint <- digest::digest(list(
  schema = 1L,
  script = digest::digest(
    file = "R/06c_binary_class_reliability.R", algo = "sha256"
  ),
  screen = digest::digest(
    file = "results/tables/binary_screen.csv", algo = "sha256"
  ),
  cohort = digest::digest(
    file = "data/processed/patient_cohort.rds", algo = "sha256"
  ),
  analysis = cfg$analysis,
  fastPLS = as.character(packageVersion("fastPLS")),
  remote_sha = as.character(packageDescription("fastPLS")$RemoteSha)
), algo = "sha256")

component_job <- function(i) {
  job <- jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(component_checkpoint_dir, paste0(model_id, ".rds"))
  if (file.exists(checkpoint)) {
    old <- tryCatch(readRDS(checkpoint), error = function(e) NULL)
    if (!is.null(old) && identical(old$fingerprint, component_fingerprint)) {
      return(old$rows)
    }
  }
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type &
      endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value[keep], levels = c(0L, 1L))
  rows <- rbindlist(lapply(seq_len(cfg$analysis$robustness_repeats), function(r) {
    seed <- cfg$analysis$seed + 10000L * r + job$job_index
    outer <- stratified_folds(y, cfg$analysis$outer_folds, seed)
    rbindlist(lapply(seq_len(cfg$analysis$outer_folds), function(fold) {
      test <- outer == fold
      train <- !test
      inner_k <- min(cfg$analysis$inner_folds, min(table(y[train])))
      inner_fold <- fastPLS:::.make_single_cv_folds(
        y[train], seq_len(sum(train)), inner_k, seed + fold
      )
      inner_counts <- data.table(
        observed = as.integer(as.character(y[train])),
        inner_fold = inner_fold
      )[, .(
        validation_positive = sum(observed == 1L),
        validation_negative = sum(observed == 0L)
      ), by = inner_fold]
      inner_counts[, `:=`(
        training_positive = sum(y[train] == "1") - validation_positive,
        training_negative = sum(y[train] == "0") - validation_negative
      )]
      tune <- fastPLS::pls.single.cv(
        X[train, , drop = FALSE], y[train],
        ncomp = cfg$analysis$components, kfold = inner_k,
        seed = seed + fold, classifier = "lda",
        lda_ridge = cfg$analysis$lda_ridge,
        selection_metric = "balanced_accuracy",
        svd.method = cfg$analysis$svd_method,
        rsvd_oversample = cfg$analysis$rsvd_oversample,
        rsvd_power = cfg$analysis$rsvd_power, fit = FALSE
      )
      data.table(
        family = job$family, tumor_type = job$tumor_type,
        endpoint = job$endpoint, `repeat` = r, outer_fold = fold,
        selected_components = as.integer(tune$best_ncomp),
        outer_training_positive = sum(y[train] == "1"),
        outer_training_negative = sum(y[train] == "0"),
        outer_test_positive = sum(y[test] == "1"),
        outer_test_negative = sum(y[test] == "0"),
        inner_folds = inner_k,
        minimum_inner_training_positive = min(inner_counts$training_positive),
        minimum_inner_training_negative = min(inner_counts$training_negative),
        minimum_inner_validation_positive = min(inner_counts$validation_positive),
        minimum_inner_validation_negative = min(inner_counts$validation_negative),
        seed = seed
      )
    }))
  }))
  saveRDS(list(fingerprint = component_fingerprint, rows = rows), checkpoint)
  rows
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
component_rows <- rbindlist(future_lapply(
  seq_len(nrow(jobs)), component_job, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table", "digest"),
  future.globals = TRUE, future.chunk.size = 1
))
setorder(component_rows, family, tumor_type, endpoint, `repeat`, outer_fold)
fwrite(component_rows,
       "results/tables/binary_selected_components_by_fold.csv")

component_summary <- component_rows[, .(
  selected_components_median = median(selected_components),
  selected_components_q1 = as.numeric(quantile(selected_components, 0.25)),
  selected_components_q3 = as.numeric(quantile(selected_components, 0.75)),
  selected_components_minimum = min(selected_components),
  selected_components_maximum = max(selected_components),
  selected_components_unique = uniqueN(selected_components),
  minimum_inner_training_positive = min(minimum_inner_training_positive),
  minimum_inner_training_negative = min(minimum_inner_training_negative),
  minimum_inner_validation_positive = min(minimum_inner_validation_positive),
  minimum_inner_validation_negative = min(minimum_inner_validation_negative)
), by = key]
fwrite(component_summary,
       "results/tables/binary_selected_component_distribution.csv")

# Repeat-to-repeat stability is evaluated only from held-out predictions.
stability_data <- copy(predictions)
stability_data[, lda_score_z := {
  s <- sd(lda_score)
  if (is.finite(s) && s > 0) (lda_score - mean(lda_score)) / s else 0
}, by = c(key, "repeat")]

stability_summary <- stability_data[, {
  score_wide <- dcast(.SD, patient + observed ~ `repeat`,
                      value.var = "lda_score_z")
  call_wide <- dcast(.SD, patient + observed ~ `repeat`,
                     value.var = "predicted")
  score_matrix <- as.matrix(score_wide[, -(1:2)])
  call_matrix <- as.matrix(call_wide[, -(1:2)])
  score_cor <- suppressWarnings(cor(score_matrix, method = "spearman",
                                    use = "pairwise.complete.obs"))
  score_cor_values <- score_cor[upper.tri(score_cor)]
  call_agreement <- vapply(combn(ncol(call_matrix), 2L, simplify = FALSE),
                           function(z) mean(call_matrix[, z[1L]] ==
                                               call_matrix[, z[2L]]),
                           numeric(1))
  data.table(
    repeat_score_spearman_mean = mean(score_cor_values, na.rm = TRUE),
    repeat_score_spearman_minimum = min(score_cor_values, na.rm = TRUE),
    repeat_class_agreement_mean = mean(call_agreement, na.rm = TRUE),
    patients_same_class_all_repeats = mean(
      apply(call_matrix, 1L, function(x) uniqueN(x) == 1L)
    ),
    median_patient_score_z_sd = median(
      apply(score_matrix, 1L, sd, na.rm = TRUE), na.rm = TRUE
    )
  )
}, by = key]
fwrite(stability_summary,
       "results/tables/binary_prediction_stability.csv")

reliability_summary <- repeat_metrics[, .(
  repeated_sensitivity_mean = mean(sensitivity),
  repeated_specificity_mean = mean(specificity),
  repeated_balanced_accuracy_mean = mean(balanced_accuracy),
  repeated_auc_mean = mean(auc),
  repeated_pr_auc_mean = mean(pr_auc),
  repeated_pr_auc_sd = sd(pr_auc),
  repeated_pr_auc_minimum = min(pr_auc),
  repeated_pr_auc_maximum = max(pr_auc),
  ppv_tcga_prevalence_mean = mean(ppv_tcga_prevalence),
  ppv_tcga_prevalence_sd = sd(ppv_tcga_prevalence),
  npv_tcga_prevalence_mean = mean(npv_tcga_prevalence),
  npv_tcga_prevalence_sd = sd(npv_tcga_prevalence),
  observed_tcga_prevalence = mean(observed_tcga_prevalence)
), by = key]
fold_summary <- fold_counts[, .(
  minimum_outer_training_positive = min(training_positive),
  minimum_outer_training_negative = min(training_negative),
  minimum_outer_test_positive = min(test_positive),
  minimum_outer_test_negative = min(test_negative),
  maximum_outer_test_positive = max(test_positive),
  maximum_outer_test_negative = max(test_negative)
), by = key]
reliability_summary <- Reduce(function(x, y) merge(x, y, by = key, all = TRUE),
                              list(reliability_summary, fold_summary,
                                   component_summary, stability_summary))
reliability_summary <- merge(
  jobs[, .(family, tumor_type, endpoint, n, positive, negative, tier,
           balanced_accuracy, adjusted_balanced_accuracy, q_value)],
  reliability_summary, by = key, all.x = TRUE
)
reliability_summary[, `:=`(
  minimum_class_n = pmin(positive, negative),
  eligible_at_50_per_class = positive >= 50L & negative >= 50L,
  model_evidence_tier = fifelse(
    positive >= 50L & negative >= 50L,
    "standard_internal_evidence", "exploratory_limited_evidence"
  ),
  default_inference = positive >= 50L & negative >= 50L,
  limited_evidence_reason = fifelse(
    positive >= 50L & negative >= 50L, "",
    paste0(
      "Fewer than 50 TCGA participants in at least one development class ",
      "(positive=", positive, ", negative=", negative,
      "); available only by explicit opt-in."
    )
  ),
  pr_auc_definition = paste(
    "Average precision: non-interpolated area under the precision-recall",
    "curve for positive class 1, calculated within each repeated nested-CV run"
  ),
  predictive_value_scope = paste(
    "Held-out PPV and NPV at the observed endpoint prevalence in the analysed",
    "TCGA cohort; not transportable prevalence-adjusted estimates"
  )
)]
setorder(reliability_summary, model_evidence_tier, family, tumor_type, endpoint)
fwrite(reliability_summary,
       "results/tables/binary_class_reliability_summary.csv")
fwrite(reliability_summary[model_evidence_tier ==
                             "exploratory_limited_evidence"],
       "results/tables/binary_limited_evidence_models.csv")

sensitivity <- data.table(
  minimum_per_class = c(20L, 50L),
  eligible_binary_targets = c(
    nrow(screen), sum(screen$positive >= 50L & screen$negative >= 50L)
  ),
  screen_positive_binary_models = c(
    nrow(jobs), sum(jobs$positive >= 50L & jobs$negative >= 50L)
  )
)
sensitivity[, `:=`(
  eligible_target_retention_percent =
    100 * eligible_binary_targets / eligible_binary_targets[1L],
  screen_positive_retention_percent =
    100 * screen_positive_binary_models / screen_positive_binary_models[1L],
  interpretation = c(
    "Prespecified atlas eligibility; models below 50 per class are exploratory",
    "Sensitivity threshold and default inference-package eligibility"
  )
)]
fwrite(sensitivity,
       "results/tables/binary_minimum_class_sensitivity.csv")

# Learning curves retain each full outer test fold and vary only the number of
# outer-training patients. This avoids evaluating fractions on different test
# populations. All 17 limited-evidence models are included.
limited_jobs <- jobs[pmin(positive, negative) < 50L]
learning_fractions <- c(0.50, 0.75, 1.00)
learning_checkpoint_dir <-
  "data/processed/checkpoints/binary_class_reliability/learning_curves"
dir.create(learning_checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
learning_fingerprint <- digest::digest(list(
  schema = 1L, component_fingerprint, fractions = learning_fractions
), algo = "sha256")

learning_job <- function(i) {
  job <- limited_jobs[i]
  model_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(learning_checkpoint_dir, paste0(model_id, ".rds"))
  if (file.exists(checkpoint)) {
    old <- tryCatch(readRDS(checkpoint), error = function(e) NULL)
    if (!is.null(old) && identical(old$fingerprint, learning_fingerprint)) {
      return(old)
    }
  }
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type &
      endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value[keep], levels = c(0L, 1L))
  patient <- d$patient[keep]
  metric_rows <- list()
  fold_rows <- list()
  counter <- 0L
  for (r in seq_len(cfg$analysis$robustness_repeats)) {
    seed <- cfg$analysis$seed + 10000L * r + job$job_index
    outer <- stratified_folds(y, cfg$analysis$outer_folds, seed)
    for (fraction in learning_fractions) {
      pred <- factor(rep(NA_character_, length(y)), levels = c("0", "1"))
      score <- rep(NA_real_, length(y))
      for (fold in seq_len(cfg$analysis$outer_folds)) {
        test <- outer == fold
        train_candidates <- which(!test)
        if (fraction < 1) {
          set.seed(seed + 200000L + as.integer(1000 * fraction) + fold)
          train <- unlist(lapply(c("0", "1"), function(level) {
            available <- train_candidates[as.character(y[train_candidates]) == level]
            sample(available, max(2L, floor(length(available) * fraction)))
          }), use.names = FALSE)
        } else {
          train <- train_candidates
        }
        inner_k <- min(cfg$analysis$inner_folds, min(table(y[train])))
        tune <- fastPLS::pls.single.cv(
          X[train, , drop = FALSE], y[train],
          ncomp = cfg$analysis$components, kfold = inner_k,
          seed = seed + fold, classifier = "lda",
          lda_ridge = cfg$analysis$lda_ridge,
          selection_metric = "balanced_accuracy",
          svd.method = cfg$analysis$svd_method,
          rsvd_oversample = cfg$analysis$rsvd_oversample,
          rsvd_power = cfg$analysis$rsvd_power, fit = FALSE
        )
        fit <- fastPLS::pls(
          X[train, , drop = FALSE], y[train],
          ncomp = tune$best_ncomp, classifier = "lda",
          lda_ridge = cfg$analysis$lda_ridge, fit = TRUE,
          return_loadings = TRUE, svd.method = cfg$analysis$svd_method,
          rsvd_oversample = cfg$analysis$rsvd_oversample,
          rsvd_power = cfg$analysis$rsvd_power,
          seed = seed + 100L + fold
        )
        z <- predict(fit, X[test, , drop = FALSE], raw_scores = TRUE)
        pred[test] <- z$Ypred[[1L]]
        score[test] <- drop(z$LDA_scores[, 2, 1] - z$LDA_scores[, 1, 1])
        counter <- counter + 1L
        fold_rows[[counter]] <- data.table(
          family = job$family, tumor_type = job$tumor_type,
          endpoint = job$endpoint, `repeat` = r,
          training_fraction = fraction, outer_fold = fold,
          training_patients = length(train),
          training_positive = sum(y[train] == "1"),
          training_negative = sum(y[train] == "0"),
          test_positive = sum(y[test] == "1"),
          test_negative = sum(y[test] == "0"),
          selected_components = as.integer(tune$best_ncomp), seed = seed
        )
      }
      md <- data.table(observed = as.integer(as.character(y)),
                       predicted = as.integer(as.character(pred)),
                       lda_score = score)
      metric_rows[[length(metric_rows) + 1L]] <- cbind(
        data.table(
          family = job$family, tumor_type = job$tumor_type,
          endpoint = job$endpoint, `repeat` = r,
          training_fraction = fraction
        ),
        binary_metrics_extended(md)
      )
    }
  }
  object <- list(
    fingerprint = learning_fingerprint,
    metrics = rbindlist(metric_rows), folds = rbindlist(fold_rows)
  )
  saveRDS(object, checkpoint)
  object
}

learning_objects <- future_lapply(
  seq_len(nrow(limited_jobs)), learning_job, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table", "digest"),
  future.globals = TRUE, future.chunk.size = 1
)
learning_metrics <- rbindlist(lapply(learning_objects, `[[`, "metrics"))
learning_folds <- rbindlist(lapply(learning_objects, `[[`, "folds"))
setorder(learning_metrics, family, tumor_type, endpoint, training_fraction,
         `repeat`)
setorder(learning_folds, family, tumor_type, endpoint, training_fraction,
         `repeat`, outer_fold)
fwrite(learning_metrics,
       "results/tables/binary_limited_evidence_learning_curve_repeats.csv")
fwrite(learning_folds,
       "results/tables/binary_limited_evidence_learning_curve_folds.csv")
learning_summary <- learning_metrics[, .(
  balanced_accuracy_mean = mean(balanced_accuracy),
  balanced_accuracy_sd = sd(balanced_accuracy),
  auc_mean = mean(auc), auc_sd = sd(auc),
  pr_auc_mean = mean(pr_auc), pr_auc_sd = sd(pr_auc),
  ppv_tcga_prevalence_mean = mean(ppv_tcga_prevalence, na.rm = TRUE),
  npv_tcga_prevalence_mean = mean(npv_tcga_prevalence, na.rm = TRUE)
), by = c(key, "training_fraction")]
learning_sizes <- learning_folds[, .(
  training_patients_mean = mean(training_patients),
  training_positive_minimum = min(training_positive),
  training_negative_minimum = min(training_negative),
  selected_components_median = median(selected_components),
  selected_components_minimum = min(selected_components),
  selected_components_maximum = max(selected_components)
), by = c(key, "training_fraction")]
learning_summary <- merge(learning_summary, learning_sizes,
                          by = c(key, "training_fraction"), all = TRUE)
fwrite(learning_summary,
       "results/tables/binary_limited_evidence_learning_curve_summary.csv")

# Add reliability and default-selection fields without changing fitted-model
# artifacts or the prespecified A/B effect categories.
registry <- fread("models/model_registry.csv")
setnames(registry, "cancer_type", "tumor_type")
old_fields <- intersect(names(registry), c(
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
))
if (length(old_fields)) registry[, (old_fields) := NULL]
registry[, `:=`(
  model_evidence_tier = "standard_internal_evidence",
  default_inference = TRUE,
  limited_evidence_reason = "",
  binary_pr_auc = NA_real_,
  binary_ppv_tcga_prevalence = NA_real_,
  binary_npv_tcga_prevalence = NA_real_,
  binary_observed_tcga_prevalence = NA_real_,
  binary_minimum_outer_test_positive = NA_integer_,
  binary_minimum_outer_test_negative = NA_integer_,
  binary_minimum_inner_training_positive = NA_integer_,
  binary_minimum_inner_training_negative = NA_integer_,
  binary_selected_components_median = NA_real_,
  binary_selected_components_q1 = NA_real_,
  binary_selected_components_q3 = NA_real_,
  binary_selected_components_minimum = NA_integer_,
  binary_selected_components_maximum = NA_integer_,
  binary_repeat_score_spearman = NA_real_,
  binary_repeat_class_agreement = NA_real_,
  binary_all_repeat_class_agreement = NA_real_
)]
registry_reliability <- reliability_summary[, .(
  family, tumor_type, endpoint, model_evidence_tier, default_inference,
  limited_evidence_reason,
  binary_pr_auc = repeated_pr_auc_mean,
  binary_ppv_tcga_prevalence = ppv_tcga_prevalence_mean,
  binary_npv_tcga_prevalence = npv_tcga_prevalence_mean,
  binary_observed_tcga_prevalence = observed_tcga_prevalence,
  binary_minimum_outer_test_positive = minimum_outer_test_positive,
  binary_minimum_outer_test_negative = minimum_outer_test_negative,
  binary_minimum_inner_training_positive = minimum_inner_training_positive,
  binary_minimum_inner_training_negative = minimum_inner_training_negative,
  binary_selected_components_median = selected_components_median,
  binary_selected_components_q1 = selected_components_q1,
  binary_selected_components_q3 = selected_components_q3,
  binary_selected_components_minimum = selected_components_minimum,
  binary_selected_components_maximum = selected_components_maximum,
  binary_repeat_score_spearman = repeat_score_spearman_mean,
  binary_repeat_class_agreement = repeat_class_agreement_mean,
  binary_all_repeat_class_agreement = patients_same_class_all_repeats
)]
binary_rows <- registry$outcome_type == "binary"
registry[binary_rows, names(registry_reliability)[-(1:3)] :=
           registry_reliability[
             .SD, on = .(family, tumor_type, endpoint),
             mget(names(registry_reliability)[-(1:3)])
           ], .SDcols = key]
setnames(registry, "tumor_type", "cancer_type")
setorder(registry, family, cancer_type, endpoint)
fwrite(registry, "models/model_registry.csv")

cat("Binary reliability:", nrow(jobs), "screen-positive models;",
    sum(jobs$positive >= 50L & jobs$negative >= 50L),
    "meet 50 per class;", nrow(limited_jobs),
    "are exploratory/limited evidence.\n")
