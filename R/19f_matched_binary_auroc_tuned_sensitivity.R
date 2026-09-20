.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")

cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))
if (!tolower(cfg$analysis$svd_method) %chin% c("rsvd", "cpu_rsvd")) {
  stop("The AUROC-tuned sensitivity is restricted to rSVD.")
}

model_names <- c("TITAN", "GigaSSL", "ProvGigaPath")
components <- as.integer(cfg$analysis$components)
component_ceiling <- max(components)
make_fastpls_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")
fastpls_description <- packageDescription("fastPLS")

cohorts <- setNames(lapply(model_names, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), model_names)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
binary_targets <- binary_targets[patient %chin% common_patients & value %in% c(0L, 1L)]

baseline <- fread("results/tables/foundation_model_matched_screen.csv")[
  outcome_type == "binary"
]
jobs <- unique(baseline[, .(
  family, subfamily, tumor_type, endpoint, source, n, positive, negative, seed
)])
setorder(jobs, family, tumor_type, endpoint)
if (nrow(jobs) != 426L) stop("Expected 426 matched binary tasks; found ", nrow(jobs))
if (anyDuplicated(jobs[, .(family, tumor_type, endpoint)])) stop("Binary jobs are not unique")

checkpoint_dir <- "data/processed/checkpoints/foundation_model_binary_auroc_tuned"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
fingerprint <- digest::digest(list(
  schema = 2L,
  script = digest::digest(file = "R/19f_matched_binary_auroc_tuned_sensitivity.R", algo = "sha256"),
  utils = digest::digest(file = "R/utils.R", algo = "sha256"),
  cohorts = vapply(model_names, function(model) {
    digest::digest(file = file.path("data/processed", paste0("patient_cohort_", model, ".rds")), algo = "sha256")
  }, character(1)),
  binary_nonmutation = digest::digest(file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"),
  binary_mutation = digest::digest(file = "data/processed/binary_targets_mutation.rds", algo = "sha256"),
  jobs = digest::digest(jobs, algo = "sha256"),
  analysis = cfg$analysis,
  estimand = "pooled inner-OOF AUROC component selection; training-only BA threshold",
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = as.character(fastpls_description$RemoteSha)
), algo = "sha256")

checkpoint_current <- function(path) {
  if (!file.exists(path)) return(FALSE)
  z <- tryCatch(readRDS(path), error = function(e) NULL)
  !is.null(z) && identical(z$fingerprint, fingerprint)
}

score_contrast <- function(prediction, component) {
  scores <- prediction$LDA_scores
  component_index <- match(component, as.integer(dimnames(scores)[[3L]]))
  if (is.na(component_index)) component_index <- component
  drop(scores[, 2L, component_index] - scores[, 1L, component_index])
}

fit_score_path <- function(Xtrain, ytrain, Xtest, seed) {
  fit <- fastPLS::pls(
    Xtrain, ytrain, ncomp = components,
    classifier = "lda", fit = TRUE, return_loadings = FALSE, rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    seed = seed
  )
  list(fit = fit, prediction = predict(fit, Xtest, raw_scores = TRUE))
}

inner_auroc_rule <- function(X, y, outer_train, inner_seed, seed_offset) {
  X_outer <- X[outer_train, , drop = FALSE]
  y_outer <- y[outer_train]
  inner_k <- min(cfg$analysis$inner_folds, min(table(y_outer)))
  inner_fold <- make_fastpls_folds(y_outer, seq_along(y_outer), inner_k, inner_seed)
  score_path <- matrix(NA_real_, nrow(X_outer), length(components),
                       dimnames = list(NULL, as.character(components)))
  inner_values <- sort(unique(inner_fold))
  for (position in seq_along(inner_values)) {
    validation <- inner_fold == inner_values[position]
    training <- !validation
    z <- fit_score_path(
      X_outer[training, , drop = FALSE], y_outer[training],
      X_outer[validation, , drop = FALSE],
      seed = as.integer(inner_seed + seed_offset + position)
    )
    for (component in components) {
      score_path[validation, as.character(component)] <-
        score_contrast(z$prediction, component)
    }
  }
  auc_path <- vapply(components, function(component) {
    rank_auc(y_outer, score_path[, as.character(component)])
  }, numeric(1))
  if (all(!is.finite(auc_path))) stop("No finite inner AUROC values")
  best_index <- which.max(auc_path)
  selected_component <- components[best_index]
  threshold <- best_balanced_threshold(
    y_outer, score_path[, as.character(selected_component)], reference = 0
  )
  list(
    component = selected_component,
    inner_auc = auc_path[best_index],
    inner_auc_path = auc_path,
    threshold = threshold$threshold,
    inner_balanced_accuracy = threshold$balanced_accuracy,
    inner_folds = inner_k
  )
}

run_job <- function(i) {
  job <- jobs[i]
  checkpoint_id <- safe_name(job$family, job$tumor_type, job$endpoint)
  checkpoint <- file.path(checkpoint_dir, paste0(checkpoint_id, ".rds"))
  if (checkpoint_current(checkpoint)) return(NULL)

  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  setorder(d, patient)
  y <- factor(d$value, levels = c(0L, 1L))
  if (nrow(d) != job$n || sum(y == "1") != job$positive || sum(y == "0") != job$negative) {
    stop("Analysis population mismatch for ", checkpoint_id)
  }
  outer_fold <- stratified_folds(y, cfg$analysis$outer_folds, job$seed)
  rows <- list()
  predictions <- list()
  folds <- list()

  for (model in model_names) {
    idx <- match(d$patient, rownames(cohorts[[model]]$X))
    if (anyNA(idx)) stop("Missing matched patient in ", model, " for ", checkpoint_id)
    X <- cohorts[[model]]$X[idx, , drop = FALSE]
    model_predictions <- vector("list", cfg$analysis$outer_folds)
    model_folds <- vector("list", cfg$analysis$outer_folds)
    for (fold in seq_len(cfg$analysis$outer_folds)) {
      test <- outer_fold == fold
      train <- !test
      rule <- inner_auroc_rule(
        X, y, train, inner_seed = job$seed + fold,
        seed_offset = 40000L + 100L * fold
      )
      z <- fit_score_path(
        X[train, , drop = FALSE], y[train], X[test, , drop = FALSE],
        seed = job$seed + 100L + fold
      )
      score <- score_contrast(z$prediction, rule$component)
      priors <- as.numeric(z$fit$lda$models[[as.character(rule$component)]]$priors)
      equal_threshold <- log(priors[[2L]] / priors[[1L]])
      call <- as.integer(score >= rule$threshold)
      model_predictions[[fold]] <- data.table(
        patient = d$patient[test], observed = as.integer(as.character(y[test])),
        outer_fold = fold, score = score, predicted_class = call,
        training_threshold_call = call,
        empirical_prior_call = as.integer(score >= 0),
        equal_prior_call = as.integer(score >= equal_threshold)
      )
      model_folds[[fold]] <- data.table(
        outer_fold = fold,
        outer_test_positive = sum(y[test] == "1"),
        outer_test_negative = sum(y[test] == "0"),
        selected_component = rule$component,
        inner_auroc = rule$inner_auc,
        inner_balanced_accuracy_at_selected_threshold = rule$inner_balanced_accuracy,
        selected_threshold = rule$threshold,
        empirical_prior_threshold = 0,
        equal_prior_threshold = equal_threshold,
        inner_folds = rule$inner_folds,
        component_at_ceiling = rule$component == component_ceiling
      )
    }
    p <- rbindlist(model_predictions)
    f <- rbindlist(model_folds)
    truth <- factor(p$observed, levels = 0:1)
    metric_row <- function(column) {
      binary_classification_metrics(
        truth, factor(p[[column]], levels = 0:1), p$score
      )
    }
    metrics <- metric_row("training_threshold_call")
    empirical <- metric_row("empirical_prior_call")
    equal <- metric_row("equal_prior_call")
    rows[[model]] <- data.table(
      foundation_model = model,
      auroc = metrics$auc,
      pr_auc = average_precision(p$observed, p$score),
      balanced_accuracy = metrics$balanced_accuracy,
      sensitivity = metrics$sensitivity,
      specificity = metrics$specificity,
      ppv = metrics$ppv,
      npv = metrics$npv,
      prevalence = metrics$prevalence,
      no_skill_pr_auc = metrics$no_skill_pr_auc,
      empirical_prior_balanced_accuracy = empirical$balanced_accuracy,
      empirical_prior_sensitivity = empirical$sensitivity,
      empirical_prior_specificity = empirical$specificity,
      empirical_prior_ppv = empirical$ppv,
      empirical_prior_npv = empirical$npv,
      equal_prior_balanced_accuracy = equal$balanced_accuracy,
      equal_prior_sensitivity = equal$sensitivity,
      equal_prior_specificity = equal$specificity,
      equal_prior_ppv = equal$ppv,
      equal_prior_npv = equal$npv,
      median_selected_component = median(f$selected_component),
      minimum_selected_component = min(f$selected_component),
      maximum_selected_component = max(f$selected_component),
      components_at_ceiling = sum(f$component_at_ceiling),
      median_inner_auroc = median(f$inner_auroc),
      median_selected_threshold = median(f$selected_threshold)
    )
    p[, foundation_model := model]
    f[, foundation_model := model]
    predictions[[model]] <- p
    folds[[model]] <- f
  }

  result <- rbindlist(rows)
  result[, `:=`(
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint, source = job$source,
    n = nrow(d), positive = sum(y == "1"), negative = sum(y == "0"),
    seed = job$seed,
    tuning_objective = "pooled inner out-of-fold AUROC",
    operating_threshold = "pooled inner out-of-fold balanced-accuracy optimum",
    primary_binary_metric = "outer out-of-fold AUROC",
    binary_crossing_rule = "AUROC >= 0.60 after inner-AUROC component tuning",
    rsvd_only = TRUE
  )]
  p <- rbindlist(predictions)
  p[, `:=`(family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint)]
  f <- rbindlist(folds)
  f[, `:=`(family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint)]
  saveRDS(list(fingerprint = fingerprint, result = result, predictions = p, folds = f),
          checkpoint, compress = "xz")
  NULL
}

start <- suppressWarnings(as.integer(Sys.getenv("AUROC_TUNE_JOB_START", "1")))
limit <- suppressWarnings(as.integer(Sys.getenv("AUROC_TUNE_JOB_LIMIT", "0")))
if (!is.finite(start) || start < 1L) start <- 1L
selected_indices <- seq.int(start, nrow(jobs))
if (is.finite(limit) && limit > 0L) selected_indices <- head(selected_indices, limit)
workers <- suppressWarnings(as.integer(Sys.getenv("TITAN_WORKERS", "6")))
if (!is.finite(workers) || workers < 1L) workers <- 1L
if (workers == 1L) {
  for (i in selected_indices) {
    run_job(i)
    cat("Completed or resumed", i, "of", nrow(jobs), "AUROC-tuned tasks\n")
    flush.console()
  }
} else {
  future::plan(future::multicore, workers = workers)
  invisible(future_lapply(
    selected_indices, run_job, future.seed = TRUE,
    future.packages = c("fastPLS", "data.table"),
    future.globals = TRUE, future.chunk.size = 1
  ))
}

expected <- file.path(checkpoint_dir, paste0(vapply(seq_len(nrow(jobs)), function(i) {
  safe_name(jobs$family[i], jobs$tumor_type[i], jobs$endpoint[i])
}, character(1)), ".rds"))
if (!all(file.exists(expected))) {
  message("Partial AUROC-tuned run: ", sum(file.exists(expected)), " of ", length(expected),
          " target checkpoints exist.")
  quit(save = "no", status = 0)
}
objects <- lapply(expected, readRDS)
if (!all(vapply(objects, function(z) identical(z$fingerprint, fingerprint), logical(1)))) {
  stop("At least one AUROC-tuned checkpoint is stale")
}
results <- rbindlist(lapply(objects, `[[`, "result"), fill = TRUE)
folds <- rbindlist(lapply(objects, `[[`, "folds"), fill = TRUE)
predictions <- rbindlist(lapply(objects, `[[`, "predictions"), fill = TRUE)
setorder(results, family, tumor_type, endpoint, foundation_model)

baseline_binary <- baseline[, .(
  foundation_model, family, tumor_type, endpoint,
  empirical_ba_tuned_auroc = fifelse(
    "primary_auc" %chin% names(baseline) & is.finite(primary_auc), primary_auc, auc
  ),
  empirical_ba_tuned_balanced_accuracy = fifelse(
    "recomputed_primary_balanced_accuracy" %chin% names(baseline) &
      is.finite(recomputed_primary_balanced_accuracy),
    recomputed_primary_balanced_accuracy, balanced_accuracy
  ),
  empirical_ba_tuned_pr_auc = fifelse(
    "primary_pr_auc" %chin% names(baseline) & is.finite(primary_pr_auc),
    primary_pr_auc, pr_auc
  ),
  empirical_ba_tuned_median_component = fifelse(
    "median_primary_component" %chin% names(baseline) &
      is.finite(median_primary_component),
    median_primary_component, selected_components_median
  )
)]
results <- baseline_binary[results, on = .(foundation_model, family, tumor_type, endpoint)]
results[, `:=`(
  auroc_delta = auroc - empirical_ba_tuned_auroc,
  balanced_accuracy_delta = balanced_accuracy - empirical_ba_tuned_balanced_accuracy,
  empirical_ba_crossing = empirical_ba_tuned_balanced_accuracy >= 0.60,
  auroc_tuned_ba_crossing = balanced_accuracy >= 0.60,
  auroc_tuned_auroc_crossing = auroc >= 0.60,
  median_component_changed = median_selected_component != empirical_ba_tuned_median_component
)]

consensus_label <- function(values) {
  n <- sum(values)
  if (n == 3L) "all three" else if (n == 2L) "exactly two" else if (n == 1L) "representation specific" else "none"
}
target_comparison <- results[, .(
  empirical_ba_consensus = consensus_label(empirical_ba_crossing),
  auroc_tuned_ba_consensus = consensus_label(auroc_tuned_ba_crossing),
  auroc_tuned_auroc_consensus = consensus_label(auroc_tuned_auroc_crossing),
  empirical_ba_crossing_count = sum(empirical_ba_crossing),
  auroc_tuned_ba_crossing_count = sum(auroc_tuned_ba_crossing),
  auroc_tuned_auroc_crossing_count = sum(auroc_tuned_auroc_crossing),
  baseline_auroc_winner = foundation_model[which.max(empirical_ba_tuned_auroc)],
  auroc_tuned_winner = foundation_model[which.max(auroc)],
  maximum_auroc_tuning_change = max(abs(auroc_delta))
), by = .(family, tumor_type, endpoint)]
target_comparison[, `:=`(
  empirical_to_auroc_tuned_ba_consensus_changed = empirical_ba_consensus != auroc_tuned_ba_consensus,
  auroc_tuned_ba_to_auroc_consensus_changed = auroc_tuned_ba_consensus != auroc_tuned_auroc_consensus,
  auroc_winner_changed = baseline_auroc_winner != auroc_tuned_winner
)]

summary <- results[, .(
  tasks = .N,
  empirical_ba_crossings = sum(empirical_ba_crossing),
  auroc_tuned_ba_crossings = sum(auroc_tuned_ba_crossing),
  auroc_tuned_auroc_crossings = sum(auroc_tuned_auroc_crossing),
  median_auroc_delta = median(auroc_delta),
  q25_auroc_delta = quantile(auroc_delta, 0.25),
  q75_auroc_delta = quantile(auroc_delta, 0.75),
  maximum_absolute_auroc_delta = max(abs(auroc_delta)),
  auroc_spearman = cor(empirical_ba_tuned_auroc, auroc, method = "spearman"),
  tasks_with_changed_median_component = sum(median_component_changed),
  component_ceiling_outer_fits = sum(components_at_ceiling),
  component_ceiling_outer_fit_fraction = sum(components_at_ceiling) / (5 * .N)
), by = foundation_model]
summary[, `:=`(
  consensus_changed_empirical_ba_to_auroc_tuned_ba = sum(target_comparison$empirical_to_auroc_tuned_ba_consensus_changed),
  auroc_winner_changed_tasks = sum(target_comparison$auroc_winner_changed)
)]

fwrite(results, "results/tables/foundation_model_binary_auroc_tuned_sensitivity.csv")
fwrite(folds, "results/tables/foundation_model_binary_auroc_tuned_folds.csv")
fwrite(summary, "results/tables/foundation_model_binary_auroc_tuned_summary.csv")
fwrite(target_comparison, "results/tables/foundation_model_binary_estimand_comparison.csv")
saveRDS(predictions, "results/predictions/foundation_model_binary_auroc_tuned_oof.rds", compress = "xz")
print(summary)
