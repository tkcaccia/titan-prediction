.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
options(fastPLS.backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

model_names <- c("TITAN", "GigaSSL", "ProvGigaPath")
cohorts <- setNames(lapply(model_names, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), model_names)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))

continuous <- readRDS("data/processed/continuous_targets.rds")
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous <- continuous[patient %chin% common_patients]
binary <- binary[patient %chin% common_patients]

continuous_jobs <- continuous[, .(n = .N, sd = sd(value)),
  by = .(family, subfamily, tumor_type, endpoint, source)
][n >= cfg$analysis$continuous_min_n & is.finite(sd) & sd > 0]
continuous_jobs[, outcome_type := "continuous"]
binary_jobs <- binary[, .(
  n = .N, positive = sum(value == 1L), negative = sum(value == 0L)
), by = .(family, subfamily, tumor_type, endpoint, source)][
  positive >= cfg$analysis$binary_min_positive &
    negative >= cfg$analysis$binary_min_negative
]
binary_jobs[, outcome_type := "binary"]
jobs <- rbindlist(list(continuous_jobs, binary_jobs), fill = TRUE)
setorder(jobs, outcome_type, family, tumor_type, endpoint)
jobs[, job_id := .I]

all_jobs <- copy(jobs)
start <- as.integer(Sys.getenv("FMPRED_JOB_START", "1"))
limit <- as.integer(Sys.getenv("FMPRED_JOB_LIMIT", "0"))
if (!is.finite(start) || start < 1L) start <- 1L
if (is.finite(limit) && limit > 0L) {
  jobs <- jobs[seq.int(start, min(start + limit - 1L, .N))]
}
checkpoint_dir <- "data/processed/checkpoints/foundation_model_comparison"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

fingerprint <- digest::digest(list(
  schema = 2L,
  utils = digest::digest(file = "R/utils.R", algo = "sha256"),
  cohorts = vapply(cohorts, `[[`, character(1), "source_sha256"),
  continuous = digest::digest(file = "data/processed/continuous_targets.rds", algo = "sha256"),
  binary_nonmutation = digest::digest(file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"),
  binary_mutation = digest::digest(file = "data/processed/binary_targets_mutation.rds", algo = "sha256"),
  analysis = cfg$analysis,
  estimand = "same outcome-labelled patients present in all three foundation-model cohorts"
), algo = "sha256")

average_precision <- function(truth, score) {
  truth <- as.integer(as.character(truth))
  keep <- truth %in% c(0L, 1L) & is.finite(score)
  truth <- truth[keep]; score <- score[keep]
  n_positive <- sum(truth == 1L)
  if (!n_positive || !sum(truth == 0L)) return(NA_real_)
  z <- data.table(score, positive = truth == 1L)[, .(
    positives = sum(positive), total = .N
  ), by = score]
  setorder(z, -score)
  z[, `:=`(cum_pos = cumsum(positives), cum_n = cumsum(total))]
  sum((z$positives / n_positive) * (z$cum_pos / z$cum_n))
}

checkpoint_current <- function(path) {
  if (!file.exists(path)) return(FALSE)
  z <- tryCatch(readRDS(path), error = function(e) NULL)
  !is.null(z) && identical(z$fingerprint, fingerprint)
}

run_job <- function(i) {
  job <- jobs[i]
  id <- safe_name(job$outcome_type, job$family, job$tumor_type, job$endpoint)
  path <- file.path(checkpoint_dir, paste0(id, ".rds"))
  if (checkpoint_current(path)) return(NULL)
  source_targets <- if (job$outcome_type == "continuous") continuous else binary
  d <- source_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  d <- d[patient %chin% common_patients]
  if (job$outcome_type == "continuous") d <- d[is.finite(value)] else d <- d[value %in% c(0L, 1L)]
  setorder(d, patient)
  y <- if (job$outcome_type == "continuous") d$value else factor(d$value, levels = c(0L, 1L))
  seed <- cfg$analysis$seed + job$job_id
  rows <- list(); predictions <- list()
  for (model in model_names) {
    cohort <- cohorts[[model]]
    idx <- match(d$patient, rownames(cohort$X))
    stopifnot(!anyNA(idx))
    X <- cohort$X[idx, , drop = FALSE]
    if (job$outcome_type == "continuous") {
      fit <- fit_continuous_nested_once(X, y, cfg$analysis, seed)
      rows[[model]] <- data.table(
        foundation_model = model, q2 = fit$q2, rmse = fit$rmse,
        spearman = fit$correlation, balanced_accuracy = NA_real_, auc = NA_real_,
        pr_auc = NA_real_, selected_components_median = median(fit$ncomp),
        selected_components_min = min(fit$ncomp), selected_components_max = max(fit$ncomp)
      )
      predictions[[model]] <- data.table(
        foundation_model = model, patient = d$patient,
        observed = as.numeric(y), predicted = fit$prediction,
        predicted_class = NA_integer_, score = NA_real_, outer_fold = fit$fold
      )
    } else {
      fit <- fit_binary_nested_once(X, y, cfg$analysis, seed)
      metrics <- binary_classification_metrics(y, fit$prediction, fit$score)
      rows[[model]] <- data.table(
        foundation_model = model, q2 = NA_real_, rmse = NA_real_, spearman = NA_real_,
        balanced_accuracy = metrics$balanced_accuracy, auc = metrics$auc,
        pr_auc = average_precision(y, fit$score),
        selected_components_median = median(fit$ncomp),
        selected_components_min = min(fit$ncomp), selected_components_max = max(fit$ncomp)
      )
      predictions[[model]] <- data.table(
        foundation_model = model, patient = d$patient,
        observed = as.integer(as.character(y)), predicted = NA_real_,
        predicted_class = as.integer(as.character(fit$prediction)),
        score = fit$score, outer_fold = fit$fold
      )
    }
  }
  result <- rbindlist(rows, use.names = TRUE, fill = TRUE)
  result[, `:=`(
    outcome_type = job$outcome_type, family = job$family,
    subfamily = job$subfamily, tumor_type = job$tumor_type,
    endpoint = job$endpoint, source = job$source, n = nrow(d),
    positive = if (job$outcome_type == "binary") sum(y == "1") else NA_integer_,
    negative = if (job$outcome_type == "binary") sum(y == "0") else NA_integer_,
    seed = seed, common_cohort = TRUE
  )]
  saveRDS(list(fingerprint = fingerprint, result = result,
               predictions = rbindlist(predictions)), path, compress = "xz")
  NULL
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
if (workers == 1L) {
  for (i in seq_len(nrow(jobs))) {
    run_job(i)
    cat("Completed or resumed", i, "of", nrow(jobs), "matched targets\n")
    flush.console()
  }
} else {
  future::plan(future::multicore, workers = workers)
  invisible(future_lapply(seq_len(nrow(jobs)), run_job, future.seed = TRUE,
                          future.packages = c("fastPLS", "data.table"),
                          future.globals = TRUE, future.chunk.size = 1))
}

paths <- file.path(checkpoint_dir, paste0(vapply(seq_len(nrow(jobs)), function(i) {
  safe_name(jobs$outcome_type[i], jobs$family[i], jobs$tumor_type[i], jobs$endpoint[i])
}, character(1)), ".rds"))
if (!all(file.exists(paths))) stop("Foundation-model comparison checkpoint missing")
objects <- lapply(paths, readRDS)
results <- rbindlist(lapply(objects, `[[`, "result"), fill = TRUE)
predictions <- rbindlist(Map(function(object, i) {
  z <- copy(object$predictions)
  z[, `:=`(
    outcome_type = jobs$outcome_type[i], family = jobs$family[i],
    subfamily = jobs$subfamily[i], tumor_type = jobs$tumor_type[i],
    endpoint = jobs$endpoint[i], source = jobs$source[i]
  )]
  z
}, objects, seq_along(objects)), fill = TRUE)
setcolorder(results, c("foundation_model", "outcome_type", "family", "subfamily",
                      "tumor_type", "endpoint", "source", "n", "positive", "negative"))
setorder(results, outcome_type, family, tumor_type, endpoint, foundation_model)
fwrite(results, "results/tables/foundation_model_matched_screen.csv")
saveRDS(predictions, "results/predictions/foundation_model_matched_oof.rds", compress = "xz")

summary <- results[, .(
  eligible_targets = .N,
  screen_statistic_ge_tier_B = if (outcome_type[1L] == "continuous")
    sum(q2 >= 0.20, na.rm = TRUE) else sum(balanced_accuracy >= 0.60, na.rm = TRUE),
  screen_statistic_ge_tier_A = if (outcome_type[1L] == "continuous")
    sum(q2 >= 0.40, na.rm = TRUE) else sum(balanced_accuracy >= 0.70, na.rm = TRUE),
  median_q2 = median(q2, na.rm = TRUE), median_auc = median(auc, na.rm = TRUE),
  median_balanced_accuracy = median(balanced_accuracy, na.rm = TRUE),
  median_pr_auc = median(pr_auc, na.rm = TRUE)
), by = .(foundation_model, outcome_type)]
fwrite(summary, "results/tables/foundation_model_matched_summary.csv")
print(summary)
