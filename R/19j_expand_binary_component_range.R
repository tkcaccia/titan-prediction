.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")

# Wider-component sensitivity for every union-positive or near-threshold binary
# task in the matched three-representation atlas. The outer folds, component
# tuning objective and rSVD seeds match the primary AUROC-centred analysis.
cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))
if (!tolower(cfg$analysis$svd_method) %chin% c("rsvd", "cpu_rsvd")) {
  stop("The component-range sensitivity is restricted to rSVD.")
}

models <- c("TITAN", "GigaSSL", "ProvGigaPath")
components <- 1:20
component_ceiling <- max(components)
make_fastpls_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")
fastpls_description <- packageDescription("fastPLS")

cohorts <- setNames(lapply(models, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), models)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
binary_targets <- binary_targets[
  patient %chin% common_patients & value %in% c(0L, 1L)
]

primary <- fread("results/tables/foundation_model_matched_screen.csv")[
  outcome_type == "binary"
]
selection <- fread("results/tables/foundation_model_fold_stability_selection.csv")[
  outcome_type == "binary"
]
jobs <- unique(selection[, .(
  family, subfamily, tumor_type, endpoint, source,
  primary_union_positive, primary_near_threshold, selection_reason
)])
seed_rows <- unique(primary[, .(family, tumor_type, endpoint, seed, n, positive, negative)])
jobs <- seed_rows[jobs, on = .(family, tumor_type, endpoint)]
setorder(jobs, family, tumor_type, endpoint)
if (nrow(jobs) != 366L) {
  stop("Expected 366 union-positive or near-threshold binary tasks; found ", nrow(jobs))
}
if (anyDuplicated(jobs[, .(family, tumor_type, endpoint)])) {
  stop("Selected binary jobs are not unique")
}

checkpoint_dir <- "data/processed/checkpoints/foundation_model_binary_components_20"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
aggregate_only <- tolower(Sys.getenv(
  "COMPONENT_RANGE_AGGREGATE_ONLY", "false"
)) %chin% c("true", "1", "yes")
fingerprint <- digest::digest(list(
  schema = 1L,
  script = digest::digest(file = "R/19j_expand_binary_component_range.R", algo = "sha256"),
  utils = digest::digest(file = "R/utils.R", algo = "sha256"),
  cohorts = vapply(models, function(model) {
    digest::digest(file = file.path(
      "data/processed", paste0("patient_cohort_", model, ".rds")
    ), algo = "sha256")
  }, character(1)),
  binary_nonmutation = digest::digest(
    file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"
  ),
  binary_mutation = digest::digest(
    file = "data/processed/binary_targets_mutation.rds", algo = "sha256"
  ),
  jobs = digest::digest(jobs, algo = "sha256"),
  analysis = cfg$analysis,
  components = components,
  estimand = "pooled inner-OOF AUROC component selection; outer OOF AUROC; training-only BA threshold",
  seed_schedule = "identical to R/19f_matched_binary_auroc_tuned_sensitivity.R",
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = as.character(fastpls_description$RemoteSha)
), algo = "sha256")

checkpoint_path <- function(job) file.path(
  checkpoint_dir, paste0(safe_name(job$family, job$tumor_type, job$endpoint), ".rds")
)
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
  score_path <- matrix(
    NA_real_, nrow(X_outer), length(components),
    dimnames = list(NULL, as.character(components))
  )
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
    threshold = threshold$threshold,
    inner_balanced_accuracy = threshold$balanced_accuracy,
    inner_folds = inner_k
  )
}

fit_model <- function(X, y, job) {
  outer_fold <- stratified_folds(y, cfg$analysis$outer_folds, job$seed)
  prediction_rows <- vector("list", cfg$analysis$outer_folds)
  fold_rows <- vector("list", cfg$analysis$outer_folds)
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
    call <- as.integer(score >= rule$threshold)
    prediction_rows[[fold]] <- data.table(
      patient = names(y)[test], observed = as.integer(as.character(y[test])),
      outer_fold = fold, score = score, predicted_class = call
    )
    fold_rows[[fold]] <- data.table(
      outer_fold = fold,
      selected_component = rule$component,
      inner_auroc = rule$inner_auc,
      inner_balanced_accuracy_at_selected_threshold = rule$inner_balanced_accuracy,
      selected_threshold = rule$threshold,
      inner_folds = rule$inner_folds,
      component_at_ceiling = rule$component == component_ceiling
    )
  }
  p <- rbindlist(prediction_rows)
  f <- rbindlist(fold_rows)
  metrics <- binary_classification_metrics(
    factor(p$observed, levels = 0:1),
    factor(p$predicted_class, levels = 0:1), p$score
  )
  list(
    metrics = metrics,
    pr_auc = average_precision(p$observed, p$score),
    predictions = p,
    folds = f
  )
}

run_job <- function(i) {
  job <- jobs[i]
  path <- checkpoint_path(job)
  # This explicit mode is only for rebuilding tables after an aggregation-only
  # code correction. Default execution remains fingerprint-strict.
  if (aggregate_only && file.exists(path)) return(NULL)
  if (checkpoint_current(path)) return(NULL)
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  setorder(d, patient)
  y <- factor(d$value, levels = c(0L, 1L))
  names(y) <- d$patient
  if (nrow(d) != job$n || sum(y == "1") != job$positive || sum(y == "0") != job$negative) {
    stop("Analysis population mismatch for ", basename(path))
  }
  rows <- list()
  folds <- list()
  predictions <- list()
  for (model in models) {
    idx <- match(d$patient, rownames(cohorts[[model]]$X))
    if (anyNA(idx)) stop("Missing matched patient in ", model)
    X <- cohorts[[model]]$X[idx, , drop = FALSE]
    fit <- tryCatch(fit_model(X, y, job), error = identity)
    if (inherits(fit, "error")) {
      rows[[model]] <- data.table(
        foundation_model = model, numerical_failure = TRUE,
        failure_message = conditionMessage(fit), fallback_used = FALSE
      )
      next
    }
    m <- fit$metrics
    rows[[model]] <- data.table(
      foundation_model = model,
      auroc = m$auc, pr_auc = fit$pr_auc,
      balanced_accuracy = m$balanced_accuracy,
      sensitivity = m$sensitivity, specificity = m$specificity,
      ppv = m$ppv, npv = m$npv,
      prevalence = m$prevalence, no_skill_pr_auc = m$no_skill_pr_auc,
      median_selected_component = median(fit$folds$selected_component),
      minimum_selected_component = min(fit$folds$selected_component),
      maximum_selected_component = max(fit$folds$selected_component),
      components_at_ceiling = sum(fit$folds$component_at_ceiling),
      numerical_failure = FALSE, failure_message = NA_character_,
      fallback_used = FALSE
    )
    fit$folds[, foundation_model := model]
    fit$predictions[, foundation_model := model]
    folds[[model]] <- fit$folds
    predictions[[model]] <- fit$predictions
  }
  result <- rbindlist(rows, fill = TRUE)
  result[, `:=`(
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint, source = job$source,
    n = job$n, positive = job$positive, negative = job$negative, seed = job$seed,
    primary_union_positive = job$primary_union_positive,
    primary_near_threshold = job$primary_near_threshold,
    selection_reason = job$selection_reason,
    component_grid = "1-20",
    tuning_objective = "pooled inner out-of-fold AUROC",
    primary_metric = "outer out-of-fold AUROC",
    operating_threshold = "pooled inner out-of-fold balanced-accuracy optimum",
    svd_method = "rSVD"
  )]
  f <- rbindlist(folds, fill = TRUE)
  if (nrow(f)) f[, `:=`(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint
  )]
  p <- rbindlist(predictions, fill = TRUE)
  if (nrow(p)) p[, `:=`(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint
  )]
  saveRDS(
    list(fingerprint = fingerprint, result = result, folds = f, predictions = p),
    path, compress = "xz"
  )
  NULL
}

start <- suppressWarnings(as.integer(Sys.getenv("COMPONENT_RANGE_JOB_START", "1")))
limit <- suppressWarnings(as.integer(Sys.getenv("COMPONENT_RANGE_JOB_LIMIT", "0")))
if (!is.finite(start) || start < 1L) start <- 1L
selected_indices <- seq.int(start, nrow(jobs))
if (is.finite(limit) && limit > 0L) selected_indices <- head(selected_indices, limit)
workers <- suppressWarnings(as.integer(Sys.getenv("TITAN_WORKERS", "6")))
if (!is.finite(workers) || workers < 1L) workers <- 1L
if (workers == 1L) {
  for (i in selected_indices) {
    run_job(i)
    if (i %% 10L == 0L || i == tail(selected_indices, 1L)) {
      cat("Completed or resumed", i, "of", nrow(jobs), "component-range tasks\n")
      flush.console()
    }
  }
} else {
  future::plan(future::multicore, workers = workers)
  invisible(future_lapply(
    selected_indices, run_job, future.seed = TRUE,
    future.packages = c("fastPLS", "data.table"),
    future.globals = TRUE, future.chunk.size = 1
  ))
}

expected <- vapply(seq_len(nrow(jobs)), function(i) checkpoint_path(jobs[i]), character(1))
if (!all(file.exists(expected))) {
  message("Partial component-range run: ", sum(file.exists(expected)), " of ",
          length(expected), " target checkpoints exist.")
  quit(save = "no", status = 0)
}
objects <- lapply(expected, readRDS)
if (!aggregate_only && !all(vapply(objects, function(x) identical(x$fingerprint, fingerprint), logical(1)))) {
  stop("At least one component-range checkpoint is stale")
}
expanded <- rbindlist(lapply(objects, `[[`, "result"), fill = TRUE)
expanded_folds <- rbindlist(lapply(objects, `[[`, "folds"), fill = TRUE)
expanded_oof <- rbindlist(lapply(objects, `[[`, "predictions"), fill = TRUE)
setorder(expanded, family, tumor_type, endpoint, foundation_model)

primary_selected <- primary[
  jobs, on = .(family, tumor_type, endpoint), nomatch = 0
]
primary_selected <- primary_selected[, .(
  foundation_model, family, tumor_type, endpoint,
  primary_auroc = auc,
  primary_pr_auc = pr_auc,
  primary_balanced_accuracy = balanced_accuracy,
  primary_selected_components_median = selected_components_median,
  primary_selected_components_max = selected_components_max,
  primary_components_at_ceiling = selected_components_at_ceiling
)]
comparison <- primary_selected[expanded, on = .(
  foundation_model, family, tumor_type, endpoint
)]
comparison[, `:=`(
  auroc_delta = auroc - primary_auroc,
  pr_auc_delta = pr_auc - primary_pr_auc,
  balanced_accuracy_delta = balanced_accuracy - primary_balanced_accuracy,
  primary_crossing = primary_auroc >= 0.60,
  expanded_crossing = auroc >= 0.60,
  crossing_change = fcase(
    primary_auroc >= 0.60 & auroc < 0.60, "lost",
    primary_auroc < 0.60 & auroc >= 0.60, "gained",
    default = "retained"
  )
)]

target_comparison <- comparison[numerical_failure == FALSE, {
  primary_winner <- foundation_model[which.max(primary_auroc)]
  expanded_winner <- foundation_model[which.max(auroc)]
  .(
    primary_winner = primary_winner,
    expanded_winner = expanded_winner,
    winner_retained = primary_winner == expanded_winner,
    primary_best_auroc = max(primary_auroc),
    expanded_best_auroc = max(auroc),
    maximum_absolute_auroc_change = max(abs(auroc_delta)),
    TITAN_primary_auroc = primary_auroc[foundation_model == "TITAN"],
    TITAN_expanded_auroc = auroc[foundation_model == "TITAN"],
    ProvGigaPath_primary_auroc = primary_auroc[foundation_model == "ProvGigaPath"],
    ProvGigaPath_expanded_auroc = auroc[foundation_model == "ProvGigaPath"],
    GigaSSL_primary_auroc = primary_auroc[foundation_model == "GigaSSL"],
    GigaSSL_expanded_auroc = auroc[foundation_model == "GigaSSL"]
  )
}, by = .(family, tumor_type, endpoint)]

summary <- comparison[, .(
  tasks = .N,
  primary_crossings = sum(primary_crossing),
  expanded_crossings = sum(expanded_crossing, na.rm = TRUE),
  lost_crossings = sum(crossing_change == "lost", na.rm = TRUE),
  gained_crossings = sum(crossing_change == "gained", na.rm = TRUE),
  median_auroc_delta = median(auroc_delta, na.rm = TRUE),
  q25_auroc_delta = quantile(auroc_delta, 0.25, na.rm = TRUE),
  q75_auroc_delta = quantile(auroc_delta, 0.75, na.rm = TRUE),
  maximum_absolute_auroc_delta = max(abs(auroc_delta), na.rm = TRUE),
  primary_tasks_with_any_ceiling_fit = sum(primary_components_at_ceiling > 0L),
  primary_outer_fits_at_ceiling = sum(primary_components_at_ceiling),
  expanded_tasks_with_any_ceiling_fit = sum(components_at_ceiling > 0L, na.rm = TRUE),
  expanded_outer_fits_at_ceiling = sum(components_at_ceiling, na.rm = TRUE),
  expanded_selected_component_median = median(median_selected_component, na.rm = TRUE),
  numerical_failures = sum(numerical_failure),
  fallbacks = sum(fallback_used)
), by = foundation_model]
summary[, `:=`(
  primary_outer_fit_ceiling_percent = 100 * primary_outer_fits_at_ceiling / (5 * tasks),
  expanded_outer_fit_ceiling_percent = 100 * expanded_outer_fits_at_ceiling / (5 * tasks),
  winners_retained = sum(target_comparison$winner_retained),
  winner_tasks = nrow(target_comparison)
)]

primary_folds <- fread("results/tables/foundation_model_binary_auroc_tuned_folds.csv")
primary_folds <- primary_folds[
  jobs, on = .(family, tumor_type, endpoint), nomatch = 0
]
primary_folds[, component_grid := "1-10"]
expanded_folds[, component_grid := "1-20"]
component_distribution <- rbindlist(list(
  primary_folds[, .(
    outer_fits = .N
  ), by = .(foundation_model, component_grid, selected_component)],
  expanded_folds[, .(
    outer_fits = .N
  ), by = .(foundation_model, component_grid, selected_component)]
))
component_distribution[, outer_fit_percent :=
  100 * outer_fits / sum(outer_fits),
  by = .(foundation_model, component_grid)
]
setorder(component_distribution, foundation_model, component_grid,
         selected_component)

variance <- fread("results/tables/foundation_model_feature_variance_audit.csv")
variance[, `:=`(
  variance_filtering = "none",
  near_constant_definition = "0 < full-cohort SD <= 1e-8",
  handling_in_pls = paste(
    "retained to preserve the released schema; training-fold centering only;",
    "a constant centered column is zero and contributes no covariance"
  ),
  numerical_failure_policy = "fail closed and record the error; no fallback estimator",
  expanded_grid_numerical_failures = summary$numerical_failures[
    match(foundation_model, summary$foundation_model)
  ],
  expanded_grid_fallbacks = summary$fallbacks[
    match(foundation_model, summary$foundation_model)
  ]
)]

titan_prov <- target_comparison[, .(
  tasks = .N,
  primary_spearman = cor(TITAN_primary_auroc, ProvGigaPath_primary_auroc,
                         method = "spearman"),
  expanded_spearman = cor(TITAN_expanded_auroc, ProvGigaPath_expanded_auroc,
                          method = "spearman"),
  primary_median_TITAN_minus_ProvGigaPath = median(
    TITAN_primary_auroc - ProvGigaPath_primary_auroc
  ),
  expanded_median_TITAN_minus_ProvGigaPath = median(
    TITAN_expanded_auroc - ProvGigaPath_expanded_auroc
  ),
  primary_TITAN_higher = sum(TITAN_primary_auroc > ProvGigaPath_primary_auroc),
  primary_ProvGigaPath_higher = sum(ProvGigaPath_primary_auroc > TITAN_primary_auroc),
  expanded_TITAN_higher = sum(TITAN_expanded_auroc > ProvGigaPath_expanded_auroc),
  expanded_ProvGigaPath_higher = sum(ProvGigaPath_expanded_auroc > TITAN_expanded_auroc),
  pairwise_leader_changed = sum(
    (TITAN_primary_auroc > ProvGigaPath_primary_auroc) !=
      (TITAN_expanded_auroc > ProvGigaPath_expanded_auroc)
  )
)]

fwrite(comparison, "results/tables/foundation_model_binary_component_range_20.csv")
fwrite(expanded_folds, "results/tables/foundation_model_binary_component_range_20_folds.csv")
fwrite(target_comparison, "results/tables/foundation_model_binary_component_range_20_targets.csv")
fwrite(summary, "results/tables/foundation_model_binary_component_range_20_summary.csv")
fwrite(component_distribution, "results/tables/foundation_model_binary_component_distribution.csv")
fwrite(variance, "results/tables/foundation_model_binary_component_feature_handling.csv")
fwrite(titan_prov, "results/tables/foundation_model_TITAN_ProvGigaPath_binary_component_range.csv")
saveRDS(
  expanded_oof,
  "results/predictions/foundation_model_binary_component_range_20_oof.rds",
  compress = "xz"
)
print(summary)
print(titan_prov)
