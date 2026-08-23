.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(future.apply)
  library(glmnet)
})
source("R/utils.R")
cfg <- load_project_config()

cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_screen <- fread("results/tables/continuous_screen.csv")
binary_screen <- fread("results/tables/binary_screen.csv")
highlighted <- fread("results/tables/highlighted_model_performance.csv")
pls_continuous <- fread("results/tables/continuous_repeated_nested_cv.csv")
pls_binary <- fread("results/tables/binary_repeated_nested_cv.csv")

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

best_balanced_threshold <- function(truth, probability) {
  truth <- factor(as.character(truth), levels = c("0", "1"))
  probability <- as.numeric(probability)
  candidates <- sort(unique(c(0, probability, 1)))
  metric <- vapply(candidates, function(threshold) {
    balanced_accuracy(truth, factor(as.integer(probability >= threshold),
                                    levels = c(0L, 1L)))
  }, numeric(1))
  best <- which(metric == max(metric, na.rm = TRUE))
  candidates[best[which.min(abs(candidates[best] - 0.5))]]
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
  data.table(
    q2 = q_squared(y, prediction),
    rmse = sqrt(mean((y - prediction)^2)),
    spearman = suppressWarnings(cor(y, prediction, method = "spearman")),
    median_lambda = median(selected_lambda)
  )
}

fit_ridge_binary_once <- function(X, y, seed) {
  y <- factor(as.character(y), levels = c("0", "1"))
  y_numeric <- as.integer(as.character(y))
  outer <- stratified_folds(y, cfg$analysis$outer_folds, seed)
  probability <- rep(NA_real_, length(y))
  prediction <- factor(rep(NA_character_, length(y)), levels = levels(y))
  selected_lambda <- selected_threshold <- numeric(cfg$analysis$outer_folds)
  for (fold in seq_len(cfg$analysis$outer_folds)) {
    test <- outer == fold
    train <- !test
    inner <- stratified_folds(y[train], cfg$analysis$inner_folds, seed + fold)
    tune <- cv.glmnet(
      X[train, , drop = FALSE], y_numeric[train], family = "binomial",
      alpha = 0, foldid = inner, type.measure = "auc", keep = TRUE,
      standardize = TRUE, intercept = TRUE, parallel = FALSE
    )
    lambda_index <- which.min(abs(tune$lambda - tune$lambda.min))
    # cv.glmnet stores binomial prevalidated values on the link (logit)
    # scale. Threshold selection must use probabilities because the outer
    # predictions below are requested with type = "response".
    inner_probability <- stats::plogis(tune$fit.preval[, lambda_index])
    threshold <- best_balanced_threshold(y[train], inner_probability)
    selected_lambda[fold] <- tune$lambda.min
    selected_threshold[fold] <- threshold
    probability[test] <- as.numeric(predict(
      tune, newx = X[test, , drop = FALSE], s = "lambda.min",
      type = "response"
    ))
    prediction[test] <- factor(
      as.integer(probability[test] >= threshold), levels = c(0L, 1L)
    )
  }
  cbind(
    binary_classification_metrics(y, prediction, probability),
    data.table(
      median_lambda = median(selected_lambda),
      median_threshold = median(selected_threshold)
    )
  )
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
    y = if (binary) factor(d$value[keep], levels = c(0L, 1L)) else d$value[keep]
  )
}

run_continuous <- function(i) {
  job <- continuous_benchmark[i]
  d <- prepare_job(job, continuous_targets)
  rbindlist(lapply(seq_len(cfg$analysis$robustness_repeats), function(repeat_id) {
    seed <- cfg$analysis$seed + 10000L * repeat_id + job$screen_index
    cbind(
      job[, .(outcome_type = "continuous", family, tumor_type, endpoint)],
      data.table(repeat_id = repeat_id, seed = seed),
      fit_ridge_continuous_once(d$X, d$y, seed)
    )
  }))
}

run_binary <- function(i) {
  job <- binary_benchmark[i]
  d <- prepare_job(job, binary_targets, binary = TRUE)
  rbindlist(lapply(seq_len(cfg$analysis$robustness_repeats), function(repeat_id) {
    seed <- cfg$analysis$seed + 10000L * repeat_id + job$screen_index
    cbind(
      job[, .(outcome_type = "binary", family, tumor_type, endpoint)],
      data.table(repeat_id = repeat_id, seed = seed),
      fit_ridge_binary_once(d$X, d$y, seed)
    )
  }))
}

workers <- as.integer(Sys.getenv("TITAN_BASELINE_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
ridge <- rbindlist(list(
  rbindlist(future_lapply(
    seq_len(nrow(continuous_benchmark)), run_continuous,
    future.seed = TRUE, future.packages = c("data.table", "glmnet")
  )),
  rbindlist(future_lapply(
    seq_len(nrow(binary_benchmark)), run_binary,
    future.seed = TRUE, future.packages = c("data.table", "glmnet")
  ))
), use.names = TRUE, fill = TRUE)
fwrite(ridge, "results/tables/ridge_baseline_repeated_nested_cv.csv")

pls <- rbindlist(list(
  pls_continuous[
    continuous_benchmark,
    on = .(family, tumor_type, endpoint), nomatch = 0L
  ][, .(outcome_type = "continuous", family, tumor_type, endpoint,
        repeat_id = get("repeat"),
        pls_primary = q2, pls_secondary = spearman)],
  pls_binary[
    binary_benchmark,
    on = .(family, tumor_type, endpoint), nomatch = 0L
  ][, .(outcome_type = "binary", family, tumor_type, endpoint,
        repeat_id = get("repeat"),
        pls_primary = balanced_accuracy, pls_secondary = auc)]
), use.names = TRUE)
ridge_metric <- rbindlist(list(
  ridge[outcome_type == "continuous", .(
    outcome_type, family, tumor_type, endpoint, repeat_id,
    ridge_primary = q2, ridge_secondary = spearman
  )],
  ridge[outcome_type == "binary", .(
    outcome_type, family, tumor_type, endpoint, repeat_id,
    ridge_primary = balanced_accuracy, ridge_secondary = auc
  )]
))
paired <- merge(
  pls, ridge_metric,
  by = c("outcome_type", "family", "tumor_type", "endpoint", "repeat_id")
)
paired[, delta_ridge_minus_pls := ridge_primary - pls_primary]
comparison <- paired[, .(
  repeats = .N,
  pls_primary_mean = mean(pls_primary),
  ridge_primary_mean = mean(ridge_primary),
  delta_ridge_minus_pls = mean(delta_ridge_minus_pls),
  delta_se = sd(delta_ridge_minus_pls) / sqrt(.N),
  pls_secondary_mean = mean(pls_secondary),
  ridge_secondary_mean = mean(ridge_secondary)
), by = .(outcome_type, family, tumor_type, endpoint)]
comparison[, `:=`(
  delta_ci_low = delta_ridge_minus_pls -
    qt(0.975, pmax(1L, repeats - 1L)) * delta_se,
  delta_ci_high = delta_ridge_minus_pls +
    qt(0.975, pmax(1L, repeats - 1L)) * delta_se
)]
comparison[, selected_method := fifelse(
  delta_ci_low > 0, "ridge",
  fifelse(delta_ci_high < 0, "PLS", "PLS (prespecified; difference uncertain)")
)]
comparison[, primary_metric := fifelse(
  outcome_type == "continuous", "Q2", "balanced accuracy"
)]
comparison[, secondary_metric := fifelse(
  outcome_type == "continuous", "Spearman correlation", "AUROC"
)]
comparison[, benchmark_scope := paste(
  "24 manuscript-highlighted PLS screen-positive models; conditional",
  "benchmark not suitable for claiming atlas-wide PLS superiority"
)]
setorder(comparison, outcome_type, -pls_primary_mean)
fwrite(comparison, "results/tables/pls_vs_ridge_highlighted_models.csv")

aggregate_summary <- comparison[, .(
  models = .N,
  pls_better = sum(selected_method == "PLS"),
  ridge_better = sum(selected_method == "ridge"),
  difference_uncertain = sum(grepl("difference uncertain", selected_method)),
  median_delta_ridge_minus_pls = median(delta_ridge_minus_pls),
  q1_delta = quantile(delta_ridge_minus_pls, 0.25),
  q3_delta = quantile(delta_ridge_minus_pls, 0.75)
), by = outcome_type]
fwrite(aggregate_summary, "results/tables/pls_vs_ridge_summary.csv")
print(aggregate_summary)
