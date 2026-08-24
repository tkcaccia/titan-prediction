.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
  library(glmnet)
})
source("R/utils.R")
cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(fastPLS.backend = backend)

cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_screen <- fread("results/tables/continuous_screen.csv")
binary_screen <- fread("results/tables/binary_screen.csv")
highlighted <- fread("results/tables/highlighted_model_performance.csv")
pls_continuous_predictions <- fread(
  "results/predictions/continuous_repeated_oof_predictions.csv.gz"
)

continuous_jobs <- continuous_screen[tier %chin% c("A", "B")]
continuous_jobs[, screen_index := .I]
continuous_benchmark <- merge(
  highlighted[outcome_type == "continuous", .(family, tumor_type, endpoint)],
  continuous_jobs, by = c("family", "tumor_type", "endpoint"), all.x = TRUE
)
binary_jobs <- binary_screen[tier %chin% c("A", "B")]
binary_jobs[, screen_index := .I]
binary_benchmark <- merge(
  highlighted[outcome_type == "binary", .(family, tumor_type, endpoint)],
  binary_jobs, by = c("family", "tumor_type", "endpoint"), all.x = TRUE
)
if (anyNA(continuous_benchmark$screen_index) || anyNA(binary_benchmark$screen_index)) {
  stop("A highlighted model is absent from the screen-positive job list")
}

# Select an operating threshold using only inner out-of-fold predictions. The
# same function and tie-breaking rule are used for PLS-LDA scores and ridge
# probabilities. The reference is used only to break exact balanced-accuracy
# ties (zero for an LDA score contrast; 0.5 for a probability).
best_balanced_threshold <- function(truth, score, reference) {
  truth <- factor(as.character(truth), levels = c("0", "1"))
  score <- as.numeric(score)
  if (length(score) != length(truth) || any(!is.finite(score))) {
    stop("Threshold selection requires one finite score per inner held-out patient")
  }
  candidates <- c(-Inf, sort(unique(score)), Inf)
  metric <- vapply(candidates, function(threshold) {
    balanced_accuracy(
      truth,
      factor(as.integer(score >= threshold), levels = c(0L, 1L))
    )
  }, numeric(1L))
  best <- which(metric == max(metric, na.rm = TRUE))
  finite_best <- best[is.finite(candidates[best])]
  if (length(finite_best)) best <- finite_best
  chosen <- best[which.min(abs(candidates[best] - reference))]
  list(threshold = candidates[[chosen]], balanced_accuracy = metric[[chosen]])
}

fit_ridge_continuous_once <- function(X, y, seed) {
  outer <- random_folds(length(y), cfg$analysis$outer_folds, seed)
  prediction <- rep(NA_real_, length(y))
  selected_lambda <- numeric(cfg$analysis$outer_folds)
  for (fold in seq_len(cfg$analysis$outer_folds)) {
    test <- outer == fold
    train <- !test
    inner <- random_folds(sum(train), cfg$analysis$inner_folds, seed + fold)
    tune <- cv.glmnet(
      X[train, , drop = FALSE], y[train], family = "gaussian", alpha = 0,
      foldid = inner, type.measure = "mse", standardize = TRUE,
      intercept = TRUE, parallel = FALSE
    )
    selected_lambda[fold] <- tune$lambda.min
    prediction[test] <- as.numeric(predict(
      tune, newx = X[test, , drop = FALSE], s = "lambda.min"
    ))
  }
  list(
    metrics = data.table(
      q2 = q_squared(y, prediction),
      rmse = sqrt(mean((y - prediction)^2)),
      spearman = suppressWarnings(cor(y, prediction, method = "spearman")),
      median_lambda = median(selected_lambda)
    ),
    prediction = prediction,
    fold = outer
  )
}

inner_pls_selection <- function(X, y, inner, seed) {
  components <- as.integer(cfg$analysis$components)
  inner_score <- matrix(NA_real_, nrow = nrow(X), ncol = length(components))
  for (inner_fold in sort(unique(inner))) {
    validation <- inner == inner_fold
    fit <- fastPLS::pls(
      X[!validation, , drop = FALSE], droplevels(y[!validation]),
      ncomp = components, classifier = "lda",
      lda_ridge = cfg$analysis$lda_ridge,
      fit = TRUE, return_loadings = TRUE,
      svd.method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      seed = seed + inner_fold
    )
    z <- predict(
      fit, X[validation, , drop = FALSE], raw_scores = TRUE
    )$LDA_scores
    score <- z[, 2L, , drop = FALSE] - z[, 1L, , drop = FALSE]
    dim(score) <- c(sum(validation), length(components))
    inner_score[validation, ] <- score
  }
  choices <- lapply(seq_along(components), function(j) {
    best_balanced_threshold(y, inner_score[, j], reference = 0)
  })
  inner_ba <- vapply(choices, `[[`, numeric(1L), "balanced_accuracy")
  best_index <- which(inner_ba == max(inner_ba, na.rm = TRUE))[[1L]]
  list(
    ncomp = components[[best_index]],
    threshold = choices[[best_index]]$threshold,
    balanced_accuracy = inner_ba[[best_index]]
  )
}

inner_ridge_selection <- function(X, y_numeric, y_factor, inner) {
  tune <- cv.glmnet(
    X, y_numeric, family = "binomial", alpha = 0,
    foldid = inner, type.measure = "auc", keep = TRUE,
    standardize = TRUE, intercept = TRUE, parallel = FALSE
  )
  inner_probability <- stats::plogis(tune$fit.preval)
  choices <- lapply(seq_len(ncol(inner_probability)), function(j) {
    if (any(!is.finite(inner_probability[, j]))) return(NULL)
    best_balanced_threshold(
      y_factor, inner_probability[, j], reference = 0.5
    )
  })
  inner_ba <- vapply(choices, function(z) {
    if (is.null(z)) NA_real_ else z$balanced_accuracy
  }, numeric(1L))
  if (!any(is.finite(inner_ba))) stop("No ridge lambda produced complete inner predictions")
  # glmnet returns lambdas from strongest to weakest regularisation. The first
  # maximum therefore gives the more regularised model when balanced accuracy ties.
  best_index <- which(inner_ba == max(inner_ba, na.rm = TRUE))[[1L]]
  list(
    fit = tune$glmnet.fit,
    lambda = tune$lambda[[best_index]],
    threshold = choices[[best_index]]$threshold,
    balanced_accuracy = inner_ba[[best_index]]
  )
}

fit_binary_pair_once <- function(X, y, seed) {
  y <- factor(as.character(y), levels = c("0", "1"))
  y_numeric <- as.integer(as.character(y))
  outer <- stratified_folds(y, cfg$analysis$outer_folds, seed)
  pls_score <- ridge_probability <- rep(NA_real_, length(y))
  pls_prediction <- ridge_prediction <- factor(
    rep(NA_character_, length(y)), levels = levels(y)
  )
  selected_pls_ncomp <- integer(cfg$analysis$outer_folds)
  selected_pls_threshold <- selected_ridge_lambda <-
    selected_ridge_threshold <- numeric(cfg$analysis$outer_folds)
  inner_pls_ba <- inner_ridge_ba <- numeric(cfg$analysis$outer_folds)

  for (fold in seq_len(cfg$analysis$outer_folds)) {
    test <- outer == fold
    train <- !test
    inner_k <- min(cfg$analysis$inner_folds, min(table(y[train])))
    inner <- stratified_folds(y[train], inner_k, seed + 1000L + fold)

    pls_choice <- inner_pls_selection(
      X[train, , drop = FALSE], droplevels(y[train]), inner,
      seed = seed + 10000L + 100L * fold
    )
    pls_fit <- fastPLS::pls(
      X[train, , drop = FALSE], droplevels(y[train]),
      ncomp = pls_choice$ncomp, classifier = "lda",
      lda_ridge = cfg$analysis$lda_ridge,
      fit = TRUE, return_loadings = TRUE,
      svd.method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      seed = seed + 20000L + fold
    )
    pls_scores <- predict(
      pls_fit, X[test, , drop = FALSE], raw_scores = TRUE
    )$LDA_scores
    pls_score[test] <- drop(pls_scores[, 2L, 1L] - pls_scores[, 1L, 1L])
    pls_prediction[test] <- factor(
      as.integer(pls_score[test] >= pls_choice$threshold),
      levels = c(0L, 1L)
    )
    selected_pls_ncomp[[fold]] <- pls_choice$ncomp
    selected_pls_threshold[[fold]] <- pls_choice$threshold
    inner_pls_ba[[fold]] <- pls_choice$balanced_accuracy

    ridge_choice <- inner_ridge_selection(
      X[train, , drop = FALSE], y_numeric[train], droplevels(y[train]), inner
    )
    ridge_probability[test] <- as.numeric(predict(
      ridge_choice$fit, newx = X[test, , drop = FALSE],
      s = ridge_choice$lambda, type = "response"
    ))
    ridge_prediction[test] <- factor(
      as.integer(ridge_probability[test] >= ridge_choice$threshold),
      levels = c(0L, 1L)
    )
    selected_ridge_lambda[[fold]] <- ridge_choice$lambda
    selected_ridge_threshold[[fold]] <- ridge_choice$threshold
    inner_ridge_ba[[fold]] <- ridge_choice$balanced_accuracy
  }

  pls_metrics <- binary_classification_metrics(y, pls_prediction, pls_score)
  ridge_metrics <- binary_classification_metrics(
    y, ridge_prediction, ridge_probability
  )
  list(
    metrics = data.table(
      pls_sensitivity = pls_metrics$sensitivity,
      pls_specificity = pls_metrics$specificity,
      pls_balanced_accuracy = pls_metrics$balanced_accuracy,
      pls_auc = pls_metrics$auc,
      ridge_sensitivity = ridge_metrics$sensitivity,
      ridge_specificity = ridge_metrics$specificity,
      ridge_balanced_accuracy = ridge_metrics$balanced_accuracy,
      ridge_auc = ridge_metrics$auc,
      median_pls_ncomp = median(selected_pls_ncomp),
      median_pls_threshold = median(selected_pls_threshold),
      median_ridge_lambda = median(selected_ridge_lambda),
      median_ridge_threshold = median(selected_ridge_threshold),
      median_inner_pls_balanced_accuracy = median(inner_pls_ba),
      median_inner_ridge_balanced_accuracy = median(inner_ridge_ba),
      outer_folds_identical = TRUE,
      inner_folds_identical = TRUE,
      threshold_selection = paste(
        "identical inner-CV rule for both methods:",
        "maximise balanced accuracy on inner out-of-fold scores"
      )
    ),
    pls_score = pls_score,
    ridge_probability = ridge_probability,
    pls_prediction = as.integer(as.character(pls_prediction)),
    ridge_prediction = as.integer(as.character(ridge_prediction)),
    fold = outer
  )
}

paired_patient_bootstrap <- function(d, metric_function, seed, times = 2000L) {
  d <- as.data.table(d)
  patients <- unique(d$patient)
  split_rows <- split(seq_len(nrow(d)), d$patient)
  point <- metric_function(d)
  set.seed(seed)
  boot <- rbindlist(lapply(seq_len(times), function(i) {
    sampled <- sample(patients, length(patients), replace = TRUE)
    rows <- unlist(split_rows[sampled], use.names = FALSE)
    metric_function(d[rows])[, .(
      delta_ridge_minus_pls,
      delta_secondary_ridge_minus_pls
    )]
  }))
  point[, `:=`(
    delta_ci_low = quantile(
      boot$delta_ridge_minus_pls, 0.025, na.rm = TRUE
    ),
    delta_ci_high = quantile(
      boot$delta_ridge_minus_pls, 0.975, na.rm = TRUE
    ),
    delta_secondary_ci_low = quantile(
      boot$delta_secondary_ridge_minus_pls, 0.025, na.rm = TRUE
    ),
    delta_secondary_ci_high = quantile(
      boot$delta_secondary_ridge_minus_pls, 0.975, na.rm = TRUE
    ),
    bootstrap_resamples = times,
    bootstrap_unit = "patient cluster",
    interval_method = paste(
      "selection-conditioned paired patient-resampling percentile interval",
      "for the ridge-minus-PLS difference in the mean of five",
      "repeat-specific out-of-fold metrics"
    ),
    uncertainty_included = paste(
      "paired patient resampling conditional on five matched repeated",
      "nested-CV out-of-fold prediction sets; both algorithms use identical",
      "patients, outer folds and inner folds"
    ),
    uncertainty_excluded = paste(
      "initial atlas screening and endpoint selection; generation of new",
      "partitions; scaling, tuning or model refitting within bootstrap",
      "replicates; external cohort, site, scanner or population shift"
    )
  )]
  point
}

continuous_pair_metrics_by_repeat <- function(d) {
  d[, .(
    pls_primary = q_squared(observed, pls_prediction),
    ridge_primary = q_squared(observed, ridge_prediction),
    pls_secondary = suppressWarnings(
      cor(observed, pls_prediction, method = "spearman")
    ),
    ridge_secondary = suppressWarnings(
      cor(observed, ridge_prediction, method = "spearman")
    )
  ), by = repeat_id][, `:=`(
    delta_ridge_minus_pls = ridge_primary - pls_primary,
    delta_secondary_ridge_minus_pls = ridge_secondary - pls_secondary
  )]
}

continuous_pair_metrics <- function(d) {
  per_repeat <- continuous_pair_metrics_by_repeat(d)
  per_repeat[, .(
    repeats = .N,
    pls_primary_mean = mean(pls_primary),
    ridge_primary_mean = mean(ridge_primary),
    delta_ridge_minus_pls = mean(delta_ridge_minus_pls),
    pls_secondary_mean = mean(pls_secondary),
    ridge_secondary_mean = mean(ridge_secondary),
    delta_secondary_ridge_minus_pls = mean(delta_secondary_ridge_minus_pls)
  )]
}

binary_pair_metrics_by_repeat <- function(d) {
  d[, .(
    pls_primary = rank_auc(observed, pls_score),
    ridge_primary = rank_auc(observed, ridge_score),
    pls_secondary = balanced_accuracy(
      factor(observed, levels = c(0L, 1L)),
      factor(pls_prediction, levels = c(0L, 1L))
    ),
    ridge_secondary = balanced_accuracy(
      factor(observed, levels = c(0L, 1L)),
      factor(ridge_prediction, levels = c(0L, 1L))
    )
  ), by = repeat_id][, `:=`(
    delta_ridge_minus_pls = ridge_primary - pls_primary,
    delta_secondary_ridge_minus_pls = ridge_secondary - pls_secondary
  )]
}

binary_pair_metrics <- function(d) {
  per_repeat <- binary_pair_metrics_by_repeat(d)
  per_repeat[, .(
    repeats = .N,
    pls_primary_mean = mean(pls_primary),
    ridge_primary_mean = mean(ridge_primary),
    delta_ridge_minus_pls = mean(delta_ridge_minus_pls),
    pls_secondary_mean = mean(pls_secondary),
    ridge_secondary_mean = mean(ridge_secondary),
    delta_secondary_ridge_minus_pls = mean(delta_secondary_ridge_minus_pls)
  )]
}

prepare_job <- function(job, targets, binary = FALSE) {
  d <- targets[
    family == job$family & tumor_type == job$tumor_type &
      endpoint == job$endpoint
  ]
  index <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(index) & if (binary) d$value %in% c(0L, 1L) else
    is.finite(d$value)
  list(
    X = cohort$X[index[keep], , drop = FALSE],
    y = if (binary) factor(d$value[keep], levels = c(0L, 1L)) else d$value[keep],
    patient = d$patient[keep]
  )
}

run_continuous <- function(i) {
  job <- continuous_benchmark[i]
  d <- prepare_job(job, continuous_targets)
  fits <- lapply(seq_len(cfg$analysis$robustness_repeats), function(repeat_id) {
    seed <- cfg$analysis$seed + 10000L * repeat_id + job$screen_index
    fit_ridge_continuous_once(d$X, d$y, seed)
  })
  list(
    metrics = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      seed <- cfg$analysis$seed + 10000L * repeat_id + job$screen_index
      cbind(
        job[, .(outcome_type = "continuous", family, tumor_type, endpoint)],
        data.table(repeat_id = repeat_id, seed = seed),
        fits[[repeat_id]]$metrics
      )
    })),
    predictions = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      cbind(
        job[, .(outcome_type = "continuous", family, tumor_type, endpoint)],
        data.table(
          repeat_id = repeat_id, patient = d$patient, observed = d$y,
          ridge_prediction = fits[[repeat_id]]$prediction,
          outer_fold = fits[[repeat_id]]$fold
        )
      )
    }))
  )
}

run_binary <- function(i) {
  job <- binary_benchmark[i]
  d <- prepare_job(job, binary_targets, binary = TRUE)
  fits <- lapply(seq_len(cfg$analysis$robustness_repeats), function(repeat_id) {
    seed <- cfg$analysis$seed + 10000L * repeat_id + job$screen_index
    fit_binary_pair_once(d$X, d$y, seed)
  })
  list(
    metrics = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      seed <- cfg$analysis$seed + 10000L * repeat_id + job$screen_index
      cbind(
        job[, .(outcome_type = "binary", family, tumor_type, endpoint)],
        data.table(repeat_id = repeat_id, seed = seed),
        fits[[repeat_id]]$metrics
      )
    })),
    predictions = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      cbind(
        job[, .(outcome_type = "binary", family, tumor_type, endpoint)],
        data.table(
          repeat_id = repeat_id, patient = d$patient,
          observed = as.integer(as.character(d$y)),
          pls_prediction = fits[[repeat_id]]$pls_prediction,
          ridge_prediction = fits[[repeat_id]]$ridge_prediction,
          pls_score = fits[[repeat_id]]$pls_score,
          ridge_score = fits[[repeat_id]]$ridge_probability,
          outer_fold = fits[[repeat_id]]$fold
        )
      )
    }))
  )
}

workers <- as.integer(Sys.getenv("TITAN_BASELINE_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
continuous_results <- future_lapply(
  seq_len(nrow(continuous_benchmark)), run_continuous,
  future.seed = TRUE, future.packages = c("data.table", "glmnet")
)
binary_results <- future_lapply(
  seq_len(nrow(binary_benchmark)), run_binary,
  future.seed = TRUE,
  future.packages = c("data.table", "fastPLS", "glmnet")
)
continuous_ridge <- rbindlist(lapply(continuous_results, `[[`, "metrics"))
continuous_ridge_predictions <- rbindlist(
  lapply(continuous_results, `[[`, "predictions")
)
binary_pair <- rbindlist(lapply(binary_results, `[[`, "metrics"))
binary_pair_predictions <- rbindlist(
  lapply(binary_results, `[[`, "predictions")
)
fwrite(
  binary_pair,
  "results/tables/binary_symmetric_pls_ridge_repeated_nested_cv.csv"
)

# Match continuous PLS and ridge predictions generated on the same seeded
# outer folds. Binary predictions are generated together above and are already
# paired exactly by patient, repeat and fold.
continuous_pls_predictions <- pls_continuous_predictions[
  continuous_benchmark[, .(family, tumor_type, endpoint)],
  on = .(family, tumor_type, endpoint), nomatch = 0L
][, .(
  outcome_type = "continuous", family, tumor_type, endpoint,
  repeat_id = get("repeat"), patient, observed,
  pls_prediction = predicted, pls_outer_fold = outer_fold
)]
continuous_pair_predictions <- merge(
  continuous_pls_predictions,
  continuous_ridge_predictions,
  by = c(
    "outcome_type", "family", "tumor_type", "endpoint",
    "repeat_id", "patient"
  ),
  suffixes = c("_pls", "_ridge")
)
if (nrow(continuous_pair_predictions) != nrow(continuous_pls_predictions) ||
    any(continuous_pair_predictions$observed_pls !=
        continuous_pair_predictions$observed_ridge) ||
    any(continuous_pair_predictions$pls_outer_fold !=
        continuous_pair_predictions$outer_fold)) {
  stop("Continuous PLS and ridge out-of-fold predictions are not exactly paired")
}
continuous_pair_predictions[, `:=`(
  observed = observed_pls,
  observed_pls = NULL,
  observed_ridge = NULL,
  outer_fold = pls_outer_fold,
  pls_outer_fold = NULL,
  pls_score = NA_real_,
  ridge_score = NA_real_
)]
matched_predictions <- rbindlist(list(
  continuous_pair_predictions,
  binary_pair_predictions
), use.names = TRUE, fill = TRUE)
setorder(
  matched_predictions, outcome_type, family, tumor_type, endpoint,
  repeat_id, patient
)
fwrite(
  matched_predictions,
  "results/predictions/pls_vs_ridge_matched_oof_predictions.csv.gz"
)

# Retain the historical ridge-only filename for downstream compatibility while
# recording that its binary rows now use the symmetric threshold procedure.
ridge <- rbindlist(list(
  continuous_ridge,
  binary_pair[, .(
    outcome_type, family, tumor_type, endpoint, repeat_id, seed,
    sensitivity = ridge_sensitivity, specificity = ridge_specificity,
    balanced_accuracy = ridge_balanced_accuracy, auc = ridge_auc,
    median_lambda = median_ridge_lambda,
    median_threshold = median_ridge_threshold,
    outer_folds_identical, inner_folds_identical, threshold_selection
  )]
), use.names = TRUE, fill = TRUE)
fwrite(ridge, "results/tables/ridge_baseline_repeated_nested_cv.csv")

comparison_keys <- unique(matched_predictions[, .(
  outcome_type, family, tumor_type, endpoint
)])
comparison <- rbindlist(lapply(seq_len(nrow(comparison_keys)), function(i) {
  job <- comparison_keys[i]
  d <- matched_predictions[
    outcome_type == job$outcome_type & family == job$family &
      tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  metric_function <- if (job$outcome_type == "continuous") {
    continuous_pair_metrics
  } else {
    binary_pair_metrics
  }
  cbind(
    job,
    data.table(patients = uniqueN(d$patient)),
    paired_patient_bootstrap(
      d, metric_function,
      seed = cfg$analysis$seed + 700000L + i,
      times = 2000L
    )
  )
}))

paired_repeat_metrics <- rbindlist(lapply(
  seq_len(nrow(comparison_keys)), function(i) {
    job <- comparison_keys[i]
    d <- matched_predictions[
      outcome_type == job$outcome_type & family == job$family &
        tumor_type == job$tumor_type & endpoint == job$endpoint
    ]
    metric_function <- if (job$outcome_type == "continuous") {
      continuous_pair_metrics_by_repeat
    } else {
      binary_pair_metrics_by_repeat
    }
    cbind(job, metric_function(d))
  }
))
setorder(
  paired_repeat_metrics, outcome_type, family, tumor_type, endpoint, repeat_id
)
fwrite(
  paired_repeat_metrics,
  "results/tables/pls_vs_ridge_paired_repeat_metrics.csv"
)
comparison[, selected_method := fifelse(
  delta_ci_low > 0, "ridge",
  fifelse(delta_ci_high < 0, "PLS", "PLS (prespecified; difference uncertain)")
)]
comparison[, primary_metric := fifelse(
  outcome_type == "continuous", "Q2", "AUROC (threshold-independent)"
)]
comparison[, secondary_metric := fifelse(
  outcome_type == "continuous", "Spearman correlation",
  "balanced accuracy (inner-CV thresholds for both)"
)]
comparison[, decision_rule_symmetry := fifelse(
  outcome_type == "binary",
  paste(
    "identical outer and inner folds; both operating thresholds selected",
    "inside each outer training set to maximise inner out-of-fold balanced accuracy"
  ),
  "not applicable to continuous regression"
)]
comparison[, benchmark_scope := paste(
  "24 manuscript-highlighted PLS screen-positive models; conditional symmetric",
  "benchmark not suitable for claiming atlas-wide PLS superiority"
)]
setorder(comparison, outcome_type, -pls_primary_mean)
fwrite(comparison, "results/tables/pls_vs_ridge_highlighted_models.csv")

aggregate_summary <- comparison[, .(
  models = .N,
  primary_metric = first(primary_metric),
  secondary_metric = first(secondary_metric),
  pls_better = sum(selected_method == "PLS"),
  ridge_better = sum(selected_method == "ridge"),
  difference_uncertain = sum(grepl("difference uncertain", selected_method)),
  median_delta_ridge_minus_pls = median(delta_ridge_minus_pls),
  q1_delta = quantile(delta_ridge_minus_pls, 0.25),
  q3_delta = quantile(delta_ridge_minus_pls, 0.75),
  median_secondary_delta_ridge_minus_pls =
    median(delta_secondary_ridge_minus_pls),
  q1_secondary_delta = quantile(delta_secondary_ridge_minus_pls, 0.25),
  q3_secondary_delta = quantile(delta_secondary_ridge_minus_pls, 0.75)
), by = outcome_type]
fwrite(aggregate_summary, "results/tables/pls_vs_ridge_summary.csv")
print(aggregate_summary)
