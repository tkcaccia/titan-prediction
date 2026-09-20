.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

model_names <- c("TITAN", "GigaSSL", "ProvGigaPath")
components <- as.integer(cfg$analysis$components)
component_ceiling <- max(components)
fastpls_description <- packageDescription("fastPLS")
fastpls_remote_sha <- as.character(fastpls_description$RemoteSha)
make_fastpls_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")

binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)

full_screen <- fread("results/tables/binary_screen.csv")
full_screen[, `:=`(
  layer = "TITAN permutation/FDR screen",
  foundation_model = "TITAN",
  current_crossing = balanced_accuracy >= 0.60,
  current_candidate = tier %chin% c("A", "B")
)]
full_jobs <- full_screen[, .(
  layer, foundation_model, family, subfamily, tumor_type, endpoint, source,
  n, positive, negative, seed, current_balanced_accuracy = balanced_accuracy,
  current_crossing, current_candidate
)]

matched_screen <- fread("results/tables/foundation_model_matched_screen.csv")
matched_screen <- matched_screen[outcome_type == "binary"]
matched_screen[, `:=`(
  layer = "matched three-representation atlas",
  current_crossing = balanced_accuracy >= 0.60,
  current_candidate = NA
)]
matched_jobs <- matched_screen[, .(
  layer, foundation_model, family, subfamily, tumor_type, endpoint, source,
  n, positive, negative, seed, current_balanced_accuracy = balanced_accuracy,
  current_crossing, current_candidate
)]

jobs <- rbindlist(list(full_jobs, matched_jobs), use.names = TRUE, fill = TRUE)
setorder(jobs, layer, foundation_model, family, tumor_type, endpoint)
jobs[, job_index := .I]
jobs[, checkpoint_id := safe_name(layer, foundation_model, family, tumor_type, endpoint)]
if (anyDuplicated(jobs$checkpoint_id)) stop("Decision-rule jobs are not unique")

scope <- tolower(Sys.getenv("DECISION_RULE_SCOPE", "all"))
if (!scope %in% c("all", "titan", "matched")) {
  stop("DECISION_RULE_SCOPE must be all, titan, or matched")
}
selected <- if (scope == "titan") {
  jobs[layer == "TITAN permutation/FDR screen"]
} else if (scope == "matched") {
  jobs[layer == "matched three-representation atlas"]
} else jobs
start <- suppressWarnings(as.integer(Sys.getenv("DECISION_RULE_JOB_START", "1")))
limit <- suppressWarnings(as.integer(Sys.getenv("DECISION_RULE_JOB_LIMIT", "0")))
if (!is.finite(start) || start < 1L) start <- 1L
if (is.finite(limit) && limit > 0L) {
  selected <- selected[seq.int(start, min(.N, start + limit - 1L))]
} else if (start > 1L) {
  selected <- selected[seq.int(start, .N)]
}

cohort_full <- readRDS("data/processed/patient_cohort.rds")
cohorts_matched <- setNames(lapply(model_names, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), model_names)
common_patients <- Reduce(intersect, lapply(cohorts_matched, function(z) rownames(z$X)))

checkpoint_dir <- "data/processed/checkpoints/binary_decision_rule_sensitivity"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
fingerprint <- digest::digest(list(
  schema = 1L,
  script = digest::digest(file = "R/19_binary_decision_rule_sensitivity.R", algo = "sha256"),
  utils = digest::digest(file = "R/utils.R", algo = "sha256"),
  full_cohort = digest::digest(file = "data/processed/patient_cohort.rds", algo = "sha256"),
  matched_cohorts = vapply(model_names, function(model) {
    digest::digest(
      file = file.path("data/processed", paste0("patient_cohort_", model, ".rds")),
      algo = "sha256"
    )
  }, character(1)),
  binary_nonmutation = digest::digest(
    file = "data/processed/binary_targets_nonmutation.rds", algo = "sha256"
  ),
  binary_mutation = digest::digest(
    file = "data/processed/binary_targets_mutation.rds", algo = "sha256"
  ),
  job_definition = digest::digest(jobs[, .(
    layer, foundation_model, family, subfamily, tumor_type, endpoint, source,
    n, positive, negative, seed
  )], algo = "sha256"),
  analysis = cfg$analysis,
  fastPLS = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = fastpls_remote_sha
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
  prediction <- predict(fit, Xtest, raw_scores = TRUE)
  list(fit = fit, prediction = prediction)
}

inner_decision_rules <- function(X, y, outer_train, inner_seed, seed_offset) {
  inner_primary <- fastPLS::pls.single.cv(
    X[outer_train, , drop = FALSE], y[outer_train], ncomp = components,
    kfold = cfg$analysis$inner_folds, seed = inner_seed,
    classifier = "lda", selection = "balanced_accuracy", rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power, fit = FALSE
  )
  X_outer <- X[outer_train, , drop = FALSE]
  y_outer <- y[outer_train]
  inner_fold <- as.integer(drop(inner_primary$fold))
  inner_values <- sort(unique(inner_fold))
  score_path <- matrix(NA_real_, nrow(X_outer), length(components))
  equal_call_path <- matrix(NA_character_, nrow(X_outer), length(components))
  colnames(score_path) <- colnames(equal_call_path) <- as.character(components)
  for (position in seq_along(inner_values)) {
    value <- inner_values[position]
    validation <- inner_fold == value
    training <- !validation
    z <- fit_score_path(
      X_outer[training, , drop = FALSE], y_outer[training],
      X_outer[validation, , drop = FALSE],
      seed = as.integer(inner_seed + seed_offset + position)
    )
    priors <- z$fit$lda$models[[as.character(component_ceiling)]]$priors
    equal_threshold <- log(as.numeric(priors[[2L]]) / as.numeric(priors[[1L]]))
    for (component in components) {
      score <- score_contrast(z$prediction, component)
      score_path[validation, as.character(component)] <- score
      equal_call_path[validation, as.character(component)] <- as.character(
        as.integer(score >= equal_threshold)
      )
    }
  }
  optimized <- lapply(components, function(component) {
    best_balanced_threshold(y_outer, score_path[, as.character(component)], reference = 0)
  })
  optimized_ba <- vapply(optimized, `[[`, numeric(1), "balanced_accuracy")
  optimized_best <- which.max(optimized_ba)
  equal_ba <- vapply(components, function(component) {
    balanced_accuracy(
      y_outer,
      factor(equal_call_path[, as.character(component)], levels = c("0", "1"))
    )
  }, numeric(1))
  equal_best <- which.max(equal_ba)
  list(
    primary_component = as.integer(inner_primary$best_ncomp[[1L]]),
    primary_inner_ba = as.numeric(inner_primary$best_metric_value[[1L]]),
    equal_component = components[equal_best],
    equal_inner_ba = equal_ba[equal_best],
    optimized_component = components[optimized_best],
    optimized_inner_ba = optimized_ba[optimized_best],
    optimized_threshold = optimized[[optimized_best]]$threshold
  )
}

run_job <- function(i) {
  job <- selected[i]
  checkpoint <- file.path(checkpoint_dir, paste0(job$checkpoint_id, ".rds"))
  if (checkpoint_current(checkpoint)) return(NULL)
  matched_layer <- job$layer == "matched three-representation atlas"
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint &
      value %in% c(0L, 1L)
  ]
  if (matched_layer) {
    d <- d[patient %chin% common_patients]
    setorder(d, patient)
    cohort <- cohorts_matched[[job$foundation_model]]
  } else {
    cohort <- cohort_full
  }
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx)
  d <- d[keep]
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value, levels = c(0L, 1L))
  if (nrow(d) != job$n || sum(y == "1") != job$positive || sum(y == "0") != job$negative) {
    stop("Analysis population mismatch for ", job$checkpoint_id)
  }
  outer_fold <- if (matched_layer) {
    stratified_folds(y, cfg$analysis$outer_folds, job$seed)
  } else {
    make_fastpls_folds(y, seq_along(y), cfg$analysis$outer_folds, job$seed)
  }
  outer_values <- sort(unique(outer_fold))
  predictions <- vector("list", length(outer_values))
  folds <- vector("list", length(outer_values))
  for (position in seq_along(outer_values)) {
    value <- outer_values[position]
    test <- outer_fold == value
    train <- !test
    inner_seed <- if (matched_layer) {
      job$seed + position
    } else {
      job$seed + 1000L + position
    }
    rules <- inner_decision_rules(
      X, y, train, inner_seed,
      seed_offset = 30000L + 100L * position
    )
    outer_seed <- if (matched_layer) {
      job$seed + 100L + position
    } else {
      job$seed + 2000L + position
    }
    z <- fit_score_path(
      X[train, , drop = FALSE], y[train], X[test, , drop = FALSE], outer_seed
    )
    primary_score <- score_contrast(z$prediction, rules$primary_component)
    equal_score <- score_contrast(z$prediction, rules$equal_component)
    optimized_score <- score_contrast(z$prediction, rules$optimized_component)
    primary_model <- z$fit$lda$models[[as.character(rules$primary_component)]]
    equal_model <- z$fit$lda$models[[as.character(rules$equal_component)]]
    primary_prior_threshold <- 0
    equal_prior_threshold <- log(
      as.numeric(equal_model$priors[[2L]]) / as.numeric(equal_model$priors[[1L]])
    )
    predictions[[position]] <- data.table(
      patient = d$patient[test], observed = as.integer(as.character(y[test])),
      outer_fold = position, primary_score = primary_score,
      equal_score = equal_score, optimized_score = optimized_score,
      primary_call = as.integer(primary_score >= primary_prior_threshold),
      equal_call = as.integer(equal_score >= equal_prior_threshold),
      optimized_call = as.integer(optimized_score >= rules$optimized_threshold)
    )
    folds[[position]] <- data.table(
      outer_fold = position,
      outer_test_positive = sum(y[test] == "1"),
      outer_test_negative = sum(y[test] == "0"),
      primary_component = rules$primary_component,
      primary_inner_ba = rules$primary_inner_ba,
      equal_component = rules$equal_component,
      equal_inner_ba = rules$equal_inner_ba,
      equal_threshold = equal_prior_threshold,
      optimized_component = rules$optimized_component,
      optimized_inner_ba = rules$optimized_inner_ba,
      optimized_threshold = rules$optimized_threshold,
      outer_training_prior_positive = as.numeric(primary_model$priors[[2L]])
    )
  }
  predictions <- rbindlist(predictions)
  folds <- rbindlist(folds)
  metric_row <- function(call, score) {
    metrics <- binary_classification_metrics(
      factor(predictions$observed, levels = 0:1),
      factor(call, levels = 0:1), score
    )
    metrics[, pr_auc := average_precision(predictions$observed, score)]
    metrics
  }
  primary <- metric_row(predictions$primary_call, predictions$primary_score)
  equal <- metric_row(predictions$equal_call, predictions$equal_score)
  optimized <- metric_row(predictions$optimized_call, predictions$optimized_score)
  result <- data.table(
    layer = job$layer, foundation_model = job$foundation_model,
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint, source = job$source,
    n = nrow(d), positive = sum(y == "1"), negative = sum(y == "0"), seed = job$seed,
    saved_current_balanced_accuracy = job$current_balanced_accuracy,
    recomputed_primary_balanced_accuracy = primary$balanced_accuracy,
    primary_sensitivity = primary$sensitivity, primary_specificity = primary$specificity,
    primary_auc = primary$auc, primary_pr_auc = primary$pr_auc,
    equal_prior_balanced_accuracy = equal$balanced_accuracy,
    equal_prior_sensitivity = equal$sensitivity,
    equal_prior_specificity = equal$specificity,
    equal_prior_auc = equal$auc, equal_prior_pr_auc = equal$pr_auc,
    optimized_balanced_accuracy = optimized$balanced_accuracy,
    optimized_sensitivity = optimized$sensitivity,
    optimized_specificity = optimized$specificity,
    optimized_auc = optimized$auc, optimized_pr_auc = optimized$pr_auc,
    current_crossing = job$current_crossing,
    current_candidate = job$current_candidate,
    recomputed_primary_crossing = primary$balanced_accuracy >= 0.60,
    equal_prior_crossing = equal$balanced_accuracy >= 0.60,
    optimized_crossing = optimized$balanced_accuracy >= 0.60,
    median_primary_component = median(folds$primary_component),
    median_equal_component = median(folds$equal_component),
    median_optimized_component = median(folds$optimized_component),
    median_optimized_threshold = median(folds$optimized_threshold),
    primary_components_at_ceiling = sum(folds$primary_component == component_ceiling),
    equal_components_at_ceiling = sum(folds$equal_component == component_ceiling),
    optimized_components_at_ceiling = sum(folds$optimized_component == component_ceiling)
  )
  predictions[, `:=`(
    layer = job$layer, foundation_model = job$foundation_model,
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint
  )]
  folds[, `:=`(
    layer = job$layer, foundation_model = job$foundation_model,
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint
  )]
  saveRDS(list(fingerprint = fingerprint, result = result,
               predictions = predictions, folds = folds), checkpoint, compress = "xz")
  NULL
}

workers <- suppressWarnings(as.integer(Sys.getenv("TITAN_WORKERS", "6")))
if (!is.finite(workers) || workers < 1L) workers <- 1L
if (workers == 1L) {
  for (i in seq_len(nrow(selected))) {
    run_job(i)
    cat("Completed or resumed", i, "of", nrow(selected), "decision-rule jobs\n")
    flush.console()
  }
} else {
  future::plan(future::multicore, workers = workers)
  invisible(future_lapply(
    seq_len(nrow(selected)), run_job, future.seed = TRUE,
    future.packages = c("fastPLS", "data.table"),
    future.globals = TRUE, future.chunk.size = 1
  ))
}

expected_paths <- file.path(checkpoint_dir, paste0(jobs$checkpoint_id, ".rds"))
available <- expected_paths[file.exists(expected_paths)]
objects <- lapply(available, readRDS)
objects <- objects[vapply(objects, function(z) identical(z$fingerprint, fingerprint), logical(1))]
results <- rbindlist(lapply(objects, `[[`, "result"), fill = TRUE)
folds <- rbindlist(lapply(objects, `[[`, "folds"), fill = TRUE)
predictions <- rbindlist(lapply(objects, `[[`, "predictions"), fill = TRUE)

results[, `:=`(
  equal_prior_delta_ba = equal_prior_balanced_accuracy - recomputed_primary_balanced_accuracy,
  optimized_delta_ba = optimized_balanced_accuracy - recomputed_primary_balanced_accuracy,
  primary_reproduction_delta = recomputed_primary_balanced_accuracy - saved_current_balanced_accuracy,
  near_threshold = saved_current_balanced_accuracy >= 0.55 & saved_current_balanced_accuracy <= 0.65,
  baseline_crossing = recomputed_primary_crossing,
  union_positive = recomputed_primary_crossing | equal_prior_crossing | optimized_crossing,
  optimized_membership_change = optimized_crossing != recomputed_primary_crossing,
  equal_prior_membership_change = equal_prior_crossing != recomputed_primary_crossing
)]
setorder(results, layer, foundation_model, family, tumor_type, endpoint)
fwrite(results, "results/tables/binary_decision_rule_sensitivity.csv")
fwrite(folds, "results/tables/binary_decision_rule_fold_thresholds.csv")
saveRDS(predictions, "results/predictions/binary_decision_rule_sensitivity_oof.rds", compress = "xz")

summarise_rules <- function(z, subset_name) {
  z[, .(
    subset = subset_name,
    tasks = .N,
    baseline_empirical_prior_crossings = sum(recomputed_primary_crossing),
    equal_prior_crossings = sum(equal_prior_crossing),
    optimized_crossings = sum(optimized_crossing),
    baseline_retained_equal = sum(recomputed_primary_crossing & equal_prior_crossing),
    baseline_lost_equal = sum(recomputed_primary_crossing & !equal_prior_crossing),
    equal_gained = sum(!recomputed_primary_crossing & equal_prior_crossing),
    baseline_retained_optimized = sum(recomputed_primary_crossing & optimized_crossing),
    baseline_lost_optimized = sum(recomputed_primary_crossing & !optimized_crossing),
    optimized_gained = sum(!recomputed_primary_crossing & optimized_crossing),
    median_equal_delta_ba = median(equal_prior_delta_ba),
    q25_equal_delta_ba = quantile(equal_prior_delta_ba, 0.25),
    q75_equal_delta_ba = quantile(equal_prior_delta_ba, 0.75),
    median_optimized_delta_ba = median(optimized_delta_ba),
    q25_optimized_delta_ba = quantile(optimized_delta_ba, 0.25),
    q75_optimized_delta_ba = quantile(optimized_delta_ba, 0.75),
    max_absolute_primary_reproduction_delta = max(abs(primary_reproduction_delta))
  ), by = .(layer, foundation_model)]
}
summary <- rbindlist(list(
  summarise_rules(results, "all eligible"),
  summarise_rules(
    results[recomputed_primary_balanced_accuracy >= 0.55 &
              recomputed_primary_balanced_accuracy <= 0.65],
    "empirical-prior BA 0.55-0.65"
  ),
  summarise_rules(results[union_positive == TRUE], "union-positive under any rule")
), use.names = TRUE, fill = TRUE)
fwrite(summary, "results/tables/binary_decision_rule_sensitivity_summary.csv")
fwrite(
  results[optimized_membership_change == TRUE | equal_prior_membership_change == TRUE],
  "results/tables/binary_decision_rule_membership_changes.csv"
)

if (length(available) < length(expected_paths)) {
  message("Partial run: ", length(available), " of ", length(expected_paths),
          " checkpoints are current. Tables contain available jobs only.")
} else {
  message("Complete decision-rule sensitivity: ", length(available), " jobs.")
}
print(summary)
