.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(digest)
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

# Construct the representative benchmark without using PLS performance. All
# eligible endpoints enter the sampling frame. Sample-size terciles are formed
# separately for continuous and binary endpoints; binary endpoints are also
# stratified by empirical terciles of the minority-class fraction. Within each
# non-empty family-by-stratum cell, a salted SHA-256 rank selects one endpoint.
# The salt and rule are fixed here so that the sample can be reconstructed from
# metadata alone and cannot change with PLS or ridge results.
selection_version <- "titan-representative-benchmark-v1"
rank_stratum <- function(x, labels) {
  r <- frank(x, ties.method = "average")
  index <- ceiling(length(labels) * r / length(x))
  labels[pmax(1L, pmin(length(labels), index))]
}
selection_hash <- function(family, tumor_type, endpoint) {
  digest(
    paste(selection_version, family, tumor_type, endpoint, sep = "|"),
    algo = "sha256", serialize = FALSE
  )
}

continuous_frame <- continuous_screen[, .(
  outcome_type = "continuous", family, tumor_type, endpoint, n,
  positive = NA_integer_, negative = NA_integer_, screen_tier = tier
)]
continuous_frame[, size_stratum := rank_stratum(
  n, c("small", "medium", "large")
)]
continuous_frame[, imbalance_stratum := "not applicable"]
continuous_frame[, minority_fraction := NA_real_]
continuous_frame[, selection_hash := mapply(
  selection_hash, family, tumor_type, endpoint, USE.NAMES = FALSE
)]
continuous_benchmark <- continuous_frame[
  order(selection_hash), .SD[1L], by = .(family, size_stratum)
]

binary_frame <- binary_screen[, .(
  outcome_type = "binary", family, tumor_type, endpoint, n,
  positive, negative, screen_tier = tier
)]
binary_frame[, minority_fraction := pmin(positive, negative) / n]
binary_frame[, size_stratum := rank_stratum(
  n, c("small", "medium", "large")
)]
binary_frame[, imbalance_stratum := rank_stratum(
  minority_fraction, c("high", "moderate", "low")
)]
binary_frame[, selection_hash := mapply(
  selection_hash, family, tumor_type, endpoint, USE.NAMES = FALSE
)]
binary_benchmark <- binary_frame[
  order(selection_hash), .SD[1L],
  by = .(family, size_stratum, imbalance_stratum)
]

setorder(continuous_benchmark, family, size_stratum, tumor_type, endpoint)
setorder(
  binary_benchmark, family, size_stratum, imbalance_stratum,
  tumor_type, endpoint
)
continuous_benchmark[, benchmark_index := seq_len(.N)]
binary_benchmark[, benchmark_index := seq_len(.N) + nrow(continuous_benchmark)]

selection_keys <- rbindlist(list(
  continuous_benchmark[, .(outcome_type, family, tumor_type, endpoint)],
  binary_benchmark[, .(outcome_type, family, tumor_type, endpoint)]
))
sampling_frame <- rbindlist(
  list(continuous_frame, binary_frame), use.names = TRUE, fill = TRUE
)
sampling_frame[, selected := FALSE]
sampling_frame[
  selection_keys,
  on = .(outcome_type, family, tumor_type, endpoint), selected := TRUE
]
sampling_frame[, `:=`(
  selection_version = selection_version,
  selection_uses_pls_performance = FALSE,
  selection_rule = paste(
    "one lowest salted SHA-256 endpoint per non-empty outcome-family and",
    "sample-size-tercile cell; binary cells additionally stratified by",
    "minority-class-fraction tercile"
  )
)]
setorder(
  sampling_frame, outcome_type, family, size_stratum,
  imbalance_stratum, selection_hash
)
fwrite(
  sampling_frame,
  "results/tables/pls_vs_ridge_representative_sampling_frame.csv"
)
representative_jobs <- rbindlist(
  list(continuous_benchmark, binary_benchmark), use.names = TRUE, fill = TRUE
)
representative_jobs[, `:=`(
  selection_version = selection_version,
  selection_uses_pls_performance = FALSE
)]
setorder(
  representative_jobs, outcome_type, family, size_stratum,
  imbalance_stratum, tumor_type, endpoint
)
fwrite(
  representative_jobs,
  "results/tables/pls_vs_ridge_representative_jobs.csv"
)
if (nrow(continuous_benchmark) != 12L || nrow(binary_benchmark) != 35L ||
    anyDuplicated(selection_keys)) {
  stop("Representative benchmark selection is incomplete or non-unique")
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

inner_pls_continuous_selection <- function(X, y, inner, seed) {
  components <- as.integer(cfg$analysis$components)
  inner_prediction <- matrix(
    NA_real_, nrow = nrow(X), ncol = length(components)
  )
  for (inner_fold in sort(unique(inner))) {
    validation <- inner == inner_fold
    fit <- fastPLS::pls(
      X[!validation, , drop = FALSE], y[!validation],
      ncomp = components, fit = TRUE, return_loadings = TRUE,
      svd.method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      seed = seed + inner_fold
    )
    fold_prediction <- predict(
      fit, X[validation, , drop = FALSE]
    )$Ypred
    dim(fold_prediction) <- c(sum(validation), length(components))
    inner_prediction[validation, ] <- fold_prediction
  }
  inner_q2 <- vapply(seq_along(components), function(j) {
    q_squared(y, inner_prediction[, j])
  }, numeric(1L))
  best_index <- which(inner_q2 == max(inner_q2, na.rm = TRUE))[[1L]]
  list(ncomp = components[[best_index]], q2 = inner_q2[[best_index]])
}

inner_ridge_continuous_selection <- function(X, y, inner) {
  tune <- cv.glmnet(
    X, y, family = "gaussian", alpha = 0, foldid = inner,
    type.measure = "mse", keep = TRUE, standardize = TRUE,
    intercept = TRUE, parallel = FALSE
  )
  inner_prediction <- as.matrix(tune$fit.preval)
  inner_q2 <- vapply(seq_len(ncol(inner_prediction)), function(j) {
    q_squared(y, inner_prediction[, j])
  }, numeric(1L))
  if (!any(is.finite(inner_q2))) {
    stop("No ridge penalty produced complete continuous inner predictions")
  }
  # glmnet orders penalties from strongest to weakest regularisation. The first
  # maximum is therefore the more regularised fit when pooled inner Q2 ties.
  best_index <- which(inner_q2 == max(inner_q2, na.rm = TRUE))[[1L]]
  list(
    fit = tune$glmnet.fit,
    lambda = tune$lambda[[best_index]],
    q2 = inner_q2[[best_index]]
  )
}

fit_continuous_pair_once <- function(X, y, seed) {
  outer <- random_folds(length(y), cfg$analysis$outer_folds, seed)
  pls_prediction <- ridge_prediction <- rep(NA_real_, length(y))
  selected_pls_ncomp <- integer(cfg$analysis$outer_folds)
  selected_lambda <- numeric(cfg$analysis$outer_folds)
  inner_pls_q2 <- inner_ridge_q2 <- numeric(cfg$analysis$outer_folds)
  for (fold in seq_len(cfg$analysis$outer_folds)) {
    test <- outer == fold
    train <- !test
    inner <- random_folds(
      sum(train), cfg$analysis$inner_folds, seed + 1000L + fold
    )

    pls_choice <- inner_pls_continuous_selection(
      X[train, , drop = FALSE], y[train], inner,
      seed = seed + 10000L + 100L * fold
    )
    pls_fit <- fastPLS::pls(
      X[train, , drop = FALSE], y[train], ncomp = pls_choice$ncomp,
      fit = TRUE, return_loadings = TRUE,
      svd.method = cfg$analysis$svd_method,
      rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      seed = seed + 20000L + fold
    )
    fold_prediction <- as.numeric(drop(
      predict(pls_fit, X[test, , drop = FALSE])$Ypred
    ))
    if (length(fold_prediction) != sum(test)) {
      stop("Continuous PLS prediction length does not match the outer fold")
    }
    pls_prediction[test] <- fold_prediction
    selected_pls_ncomp[[fold]] <- pls_choice$ncomp
    inner_pls_q2[[fold]] <- pls_choice$q2

    ridge_choice <- inner_ridge_continuous_selection(
      X[train, , drop = FALSE], y[train], inner
    )
    ridge_prediction[test] <- as.numeric(predict(
      ridge_choice$fit, newx = X[test, , drop = FALSE],
      s = ridge_choice$lambda
    ))
    selected_lambda[[fold]] <- ridge_choice$lambda
    inner_ridge_q2[[fold]] <- ridge_choice$q2
  }
  list(
    metrics = data.table(
      pls_q2 = q_squared(y, pls_prediction),
      pls_rmse = sqrt(mean((y - pls_prediction)^2)),
      pls_spearman = suppressWarnings(
        cor(y, pls_prediction, method = "spearman")
      ),
      ridge_q2 = q_squared(y, ridge_prediction),
      ridge_rmse = sqrt(mean((y - ridge_prediction)^2)),
      ridge_spearman = suppressWarnings(
        cor(y, ridge_prediction, method = "spearman")
      ),
      median_pls_ncomp = median(selected_pls_ncomp),
      median_ridge_lambda = median(selected_lambda),
      median_inner_pls_q2 = median(inner_pls_q2),
      median_inner_ridge_q2 = median(inner_ridge_q2),
      outer_folds_identical = TRUE,
      inner_folds_identical = TRUE,
      tuning_rule_symmetry = paste(
        "identical outer and inner folds; both PLS component count and",
        "ridge penalty selected by maximising pooled inner out-of-fold Q2"
      )
    ),
    pls_prediction = pls_prediction,
    ridge_prediction = ridge_prediction,
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
      "metadata-stratified benchmark-sample selection; generation of new",
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
    seed <- cfg$analysis$seed + 10000L * repeat_id + job$benchmark_index
    fit_continuous_pair_once(d$X, d$y, seed)
  })
  list(
    metrics = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      seed <- cfg$analysis$seed +
        10000L * repeat_id + job$benchmark_index
      cbind(
        job[, .(
          outcome_type, family, tumor_type, endpoint,
          size_stratum, imbalance_stratum, screen_tier
        )],
        data.table(repeat_id = repeat_id, seed = seed),
        fits[[repeat_id]]$metrics
      )
    })),
    predictions = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      cbind(
        job[, .(
          outcome_type, family, tumor_type, endpoint,
          size_stratum, imbalance_stratum, screen_tier
        )],
        data.table(
          repeat_id = repeat_id, patient = d$patient, observed = d$y,
          pls_prediction = fits[[repeat_id]]$pls_prediction,
          ridge_prediction = fits[[repeat_id]]$ridge_prediction,
          pls_score = NA_real_, ridge_score = NA_real_,
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
    seed <- cfg$analysis$seed + 10000L * repeat_id + job$benchmark_index
    fit_binary_pair_once(d$X, d$y, seed)
  })
  list(
    metrics = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      seed <- cfg$analysis$seed +
        10000L * repeat_id + job$benchmark_index
      cbind(
        job[, .(
          outcome_type, family, tumor_type, endpoint,
          size_stratum, imbalance_stratum, screen_tier
        )],
        data.table(repeat_id = repeat_id, seed = seed),
        fits[[repeat_id]]$metrics
      )
    })),
    predictions = rbindlist(lapply(seq_along(fits), function(repeat_id) {
      cbind(
        job[, .(
          outcome_type, family, tumor_type, endpoint,
          size_stratum, imbalance_stratum, screen_tier
        )],
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
  future.seed = TRUE, future.packages = c("data.table", "fastPLS", "glmnet")
)
binary_results <- future_lapply(
  seq_len(nrow(binary_benchmark)), run_binary,
  future.seed = TRUE,
  future.packages = c("data.table", "fastPLS", "glmnet")
)
continuous_pair <- rbindlist(lapply(continuous_results, `[[`, "metrics"))
continuous_pair_predictions <- rbindlist(
  lapply(continuous_results, `[[`, "predictions")
)
binary_pair <- rbindlist(lapply(binary_results, `[[`, "metrics"))
binary_pair_predictions <- rbindlist(
  lapply(binary_results, `[[`, "predictions")
)
fwrite(
  binary_pair,
  paste0(
    "results/tables/",
    "binary_symmetric_pls_ridge_representative_repeated_nested_cv.csv"
  )
)
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
  paste0(
    "results/predictions/",
    "pls_vs_ridge_representative_matched_oof_predictions.csv.gz"
  )
)

repeat_model_metrics <- rbindlist(
  list(continuous_pair, binary_pair), use.names = TRUE, fill = TRUE
)
fwrite(
  repeat_model_metrics,
  paste0(
    "results/tables/",
    "pls_vs_ridge_representative_repeated_nested_cv.csv"
  )
)

comparison_keys <- unique(matched_predictions[, .(
  outcome_type, family, tumor_type, endpoint, size_stratum,
  imbalance_stratum, screen_tier
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
  paste0(
    "results/tables/",
    "pls_vs_ridge_representative_paired_repeat_metrics.csv"
  )
)
comparison[, selected_method := fifelse(
  delta_ci_low > 0, "ridge",
  fifelse(delta_ci_high < 0, "PLS", "uncertain")
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
  "47 metadata-stratified endpoints selected from all 2073 eligible tests",
  "without reference to PLS performance; representative rather than atlas-wide"
)]
setorder(comparison, outcome_type, -pls_primary_mean)
fwrite(
  comparison,
  "results/tables/pls_vs_ridge_representative_models.csv"
)

aggregate_summary <- comparison[, .(
  models = .N,
  primary_metric = first(primary_metric),
  secondary_metric = first(secondary_metric),
  pls_better = sum(selected_method == "PLS"),
  ridge_better = sum(selected_method == "ridge"),
  difference_uncertain = sum(selected_method == "uncertain"),
  median_delta_ridge_minus_pls = median(delta_ridge_minus_pls),
  q1_delta = quantile(delta_ridge_minus_pls, 0.25),
  q3_delta = quantile(delta_ridge_minus_pls, 0.75),
  median_secondary_delta_ridge_minus_pls =
    median(delta_secondary_ridge_minus_pls),
  q1_secondary_delta = quantile(delta_secondary_ridge_minus_pls, 0.25),
  q3_secondary_delta = quantile(delta_secondary_ridge_minus_pls, 0.75)
), by = outcome_type]
fwrite(
  aggregate_summary,
  "results/tables/pls_vs_ridge_representative_summary.csv"
)

summarise_stratum <- function(d, stratifier_label, stratum_column) {
  out <- d[, .(
    models = .N,
    median_delta_ridge_minus_pls = median(delta_ridge_minus_pls),
    q1_delta = quantile(delta_ridge_minus_pls, 0.25),
    q3_delta = quantile(delta_ridge_minus_pls, 0.75),
    pls_better = sum(selected_method == "PLS"),
    ridge_better = sum(selected_method == "ridge"),
    difference_uncertain = sum(selected_method == "uncertain")
  ), by = c("outcome_type", stratum_column)]
  setnames(out, stratum_column, "stratum")
  out[, stratifier := stratifier_label]
  setcolorder(out, c("outcome_type", "stratifier", "stratum"))
  out
}
stratified_summary <- rbindlist(list(
  summarise_stratum(comparison, "outcome family", "family"),
  summarise_stratum(comparison, "sample size", "size_stratum"),
  summarise_stratum(
    comparison[outcome_type == "binary"],
    "class imbalance", "imbalance_stratum"
  )
), use.names = TRUE)
setorder(stratified_summary, outcome_type, stratifier, stratum)
fwrite(
  stratified_summary,
  "results/tables/pls_vs_ridge_representative_stratified_summary.csv"
)
print(aggregate_summary)
