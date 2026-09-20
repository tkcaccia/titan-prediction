.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
options(backend = tolower(Sys.getenv("TITAN_BACKEND", "cpu")))

# Cohort-structure audit for the primary matched atlas. Every
# union-positive task is refitted with complete TCGA tissue-source-site codes
# held apart in both outer and inner validation. A matched-random partition
# reproduces outer-fold sizes and, for binary tasks, class counts. Patients,
# folds, seeds and tuning rules are identical across representations.
model_names <- c("TITAN", "GigaSSL", "ProvGigaPath")
task_cols <- c("outcome_type", "family", "subfamily", "tumor_type",
               "endpoint", "source")
comparison <- fread("results/tables/foundation_model_target_comparison.csv")
jobs <- comparison[supported_by_n > 0L]
setorder(jobs, outcome_type, family, tumor_type, endpoint)
jobs[, grouped_job_id := .I]

cohorts <- setNames(lapply(model_names, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), model_names)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
continuous <- readRDS("data/processed/continuous_targets.rds")[patient %chin% common_patients]
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)[patient %chin% common_patients]
make_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")

matched_outer <- function(grouped, y, binary_outcome, seed) {
  set.seed(seed)
  out <- rep(NA_integer_, length(grouped))
  folds <- sort(unique(grouped))
  if (binary_outcome) {
    for (lev in levels(y)) {
      idx <- sample(which(y == lev))
      counts <- table(factor(grouped[y == lev], levels = folds))
      cursor <- 1L
      for (f in seq_along(counts)) {
        if (counts[[f]] > 0L) {
          take <- idx[cursor:(cursor + counts[[f]] - 1L)]
          out[take] <- folds[[f]]
          cursor <- cursor + counts[[f]]
        }
      }
    }
  } else {
    idx <- sample(seq_along(grouped))
    counts <- table(factor(grouped, levels = folds))
    cursor <- 1L
    for (f in seq_along(counts)) {
      take <- idx[cursor:(cursor + counts[[f]] - 1L)]
      out[take] <- folds[[f]]
      cursor <- cursor + counts[[f]]
    }
  }
  stopifnot(!anyNA(out))
  out
}

fit_on_outer <- function(X, y, code, outer, grouped_inner,
                         binary_outcome, seed) {
  if (binary_outcome) {
    return(fit_binary_nested_auroc_once(
      X, y, cfg$analysis, seed, outer = outer,
      inner_constrain = if (grouped_inner) code else NULL
    ))
  }
  folds <- sort(unique(outer))
  prediction <- if (binary_outcome) {
    factor(rep(NA_character_, length(y)), levels = levels(y))
  } else rep(NA_real_, length(y))
  score <- rep(NA_real_, length(y))
  selected <- integer(length(folds))
  for (ff in seq_along(folds)) {
    test <- outer == folds[[ff]]
    train <- !test
    inner_args <- list(
      Xdata = X[train, , drop = FALSE], Ydata = y[train],
      ncomp = cfg$analysis$components,
      constrain = if (grouped_inner) code[train] else NULL,
      kfold = cfg$analysis$inner_folds,
      classifier = "argmax", rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      seed = seed + 2000L + ff, fit = FALSE
    )
    inner <- do.call(fastPLS::pls.single.cv, inner_args)
    selected[[ff]] <- inner$best_ncomp
    fit <- fastPLS::pls(
      X[train, , drop = FALSE], y[train], ncomp = selected[[ff]],
      classifier = "argmax", fit = TRUE,
      return_loadings = TRUE, rsvd_oversample = cfg$analysis$rsvd_oversample,
      rsvd_power = cfg$analysis$rsvd_power,
      seed = seed + 3000L + ff
    )
    z <- predict(fit, X[test, , drop = FALSE])
    fold_prediction <- as.numeric(drop(z$Ypred))
    if (length(fold_prediction) != sum(test)) {
      stop("Continuous prediction length mismatch")
    }
    prediction[test] <- fold_prediction
  }
  list(prediction = prediction, score = score, ncomp = selected)
}

site_only_oof <- function(y, code, binary_outcome, seed) {
  fold <- if (binary_outcome) {
    stratified_folds(y, cfg$analysis$outer_folds, seed)
  } else random_folds(length(y), cfg$analysis$outer_folds, seed)
  prediction <- rep(NA_real_, length(y))
  numeric_y <- if (binary_outcome) as.integer(as.character(y)) else y
  for (f in sort(unique(fold))) {
    test <- fold == f
    train <- !test
    global <- mean(numeric_y[train])
    means <- data.table(code = code[train], value = numeric_y[train])[
      , .(mean_value = mean(value)), by = code
    ]
    prediction[test] <- means$mean_value[match(code[test], means$code)]
    prediction[test][!is.finite(prediction[test])] <- global
  }
  prediction
}

metrics <- function(y, fit, binary_outcome) {
  if (binary_outcome) {
    m <- binary_classification_metrics(y, fit$prediction, fit$score)
    return(data.table(
      q2 = NA_real_, rmse = NA_real_, spearman = NA_real_,
      sensitivity = m$sensitivity, specificity = m$specificity,
      ppv = m$ppv, npv = m$npv,
      balanced_accuracy = m$balanced_accuracy, auc = m$auc,
      pr_auc = average_precision(y, fit$score),
      prevalence = m$prevalence, no_skill_pr_auc = m$no_skill_pr_auc
    ))
  }
  data.table(
    q2 = q_squared(y, fit$prediction),
    rmse = sqrt(mean((y - fit$prediction)^2)),
    spearman = suppressWarnings(cor(y, fit$prediction, method = "spearman")),
    sensitivity = NA_real_, specificity = NA_real_,
    ppv = NA_real_, npv = NA_real_,
    balanced_accuracy = NA_real_, auc = NA_real_, pr_auc = NA_real_,
    prevalence = NA_real_, no_skill_pr_auc = NA_real_
  )
}

checkpoint_dir <- "data/processed/checkpoints/foundation_model_tss_grouped_union_positive_auroc"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
fastpls_description <- packageDescription("fastPLS")
fingerprint <- digest::digest(list(
  schema = 2L,
  specification = paste0(
    "all matched-atlas union-positive tasks; grouped outer and inner folds; ",
    "matched-random outer-size/class control; binary components selected by ",
    "pooled inner OOF AUROC and binary crossings defined by AUROC >= 0.60"
  ),
  script = digest::digest(file = "R/16e_foundation_model_tss_grouped_sensitivity.R",
                          algo = "sha256"),
  utils = digest::digest(file = "R/utils.R", algo = "sha256"),
  primary = digest::digest(file = "results/tables/foundation_model_target_comparison.csv", algo = "sha256"),
  cohorts = vapply(cohorts, `[[`, character(1), "source_sha256"),
  analysis = cfg$analysis,
  fastPLS_version = as.character(packageVersion("fastPLS")),
  fastPLS_remote_sha = as.character(fastpls_description$RemoteSha)
), algo = "sha256")

checkpoint_path <- function(i) file.path(checkpoint_dir, sprintf("job_%04d.rds", i))
# These two checkpoint fingerprints were produced by the same fitted-model
# specification before the error-row schema was completed. Successful rows are
# numerically reusable because the change affects only how an infeasible fit is
# represented. Structural checks prevent reuse of incomplete error rows.
compatible_success_fingerprints <- c(
  "a47a494ab2a1cf79c1114d114acdf372380d837531e829ec107904627274e805",
  "fec7e66469297ad0ff78a50fdc4f02378ba96f57fb92c8261cc5f6737cd0e8d3"
)
checkpoint_current <- function(path) {
  if (!file.exists(path)) return(FALSE)
  z <- tryCatch(readRDS(path), error = function(e) NULL)
  if (is.null(z)) return(FALSE)
  if (identical(z$fingerprint, fingerprint)) return(TRUE)
  identical(z$fingerprint %chin% compatible_success_fingerprints, TRUE) &&
    !is.null(z$result) && nrow(z$result) == 3L &&
    all(z$result$feasible %in% TRUE) &&
    all(c("grouped_crossing", "grouped_effect", "matched_random_effect") %chin%
          names(z$result))
}

run_job <- function(i) {
  path <- checkpoint_path(i)
  if (checkpoint_current(path)) return(NULL)
  job <- jobs[grouped_job_id == i]
  target <- if (job$outcome_type == "continuous") continuous else binary
  d <- target[family == job$family & subfamily == job$subfamily &
                tumor_type == job$tumor_type & endpoint == job$endpoint &
                source == job$source]
  d <- if (job$outcome_type == "continuous") d[is.finite(value)] else d[value %in% c(0L, 1L)]
  setorder(d, patient)
  binary_outcome <- job$outcome_type == "binary"
  y <- if (binary_outcome) factor(d$value, levels = c(0L, 1L)) else d$value
  code <- substr(d$patient, 6L, 7L)
  seed <- cfg$analysis$seed + 700000L + i
  grouped_outer <- tryCatch(
    make_folds(Ydata = y, constrain = code,
               kfold = cfg$analysis$outer_folds, seed = seed),
    error = function(e) e
  )
  if (inherits(grouped_outer, "error")) {
    result <- data.table(
      foundation_model = model_names, feasible = FALSE,
      error = conditionMessage(grouped_outer)
    )
    fold_audit <- data.table(error = conditionMessage(grouped_outer))
  } else {
    matched <- matched_outer(grouped_outer, y, binary_outcome, seed + 900000L)
    result <- rbindlist(lapply(model_names, function(model) {
      idx <- match(d$patient, rownames(cohorts[[model]]$X))
      stopifnot(!anyNA(idx))
      X <- cohorts[[model]]$X[idx, , drop = FALSE]
      object <- tryCatch({
        grouped_fit <- fit_on_outer(X, y, code, grouped_outer, TRUE,
                                    binary_outcome, seed)
        matched_fit <- fit_on_outer(X, y, code, matched, FALSE,
                                    binary_outcome, seed)
        list(grouped = grouped_fit, matched = matched_fit)
      }, error = function(e) e)
      if (inherits(object, "error")) {
        return(data.table(
          foundation_model = model, feasible = FALSE,
          error = conditionMessage(object),
          grouped_q2 = NA_real_, grouped_rmse = NA_real_,
          grouped_spearman = NA_real_, grouped_sensitivity = NA_real_,
          grouped_specificity = NA_real_, grouped_ppv = NA_real_,
          grouped_npv = NA_real_, grouped_balanced_accuracy = NA_real_,
          grouped_auc = NA_real_, grouped_pr_auc = NA_real_,
          grouped_prevalence = NA_real_, grouped_no_skill_pr_auc = NA_real_,
          matched_random_q2 = NA_real_,
          matched_random_balanced_accuracy = NA_real_,
          matched_random_auc = NA_real_, matched_random_pr_auc = NA_real_,
          matched_random_ppv = NA_real_, matched_random_npv = NA_real_,
          grouped_effect = NA_real_, matched_random_effect = NA_real_,
          grouped_crossing = FALSE,
          selected_components_grouped_median = NA_real_,
          selected_components_matched_median = NA_real_,
          selected_components_grouped_at_ceiling = NA_integer_,
          grouped_degenerate_inner_fold_events = NA_integer_,
          matched_degenerate_inner_fold_events = NA_integer_,
          grouped_constant_fallback_outer_fits = NA_integer_,
          matched_constant_fallback_outer_fits = NA_integer_,
          grouped_informative_component_selections = NA_integer_,
          matched_informative_component_selections = NA_integer_,
          grouped_estimable_outer_fits = NA_integer_,
          matched_estimable_outer_fits = NA_integer_,
          grouped_minimum_inner_training_positive = NA_integer_,
          grouped_minimum_inner_training_negative = NA_integer_
        ))
      }
      grouped_metrics <- metrics(y, object$grouped, binary_outcome)
      matched_metrics <- metrics(y, object$matched, binary_outcome)
      data.table(
        foundation_model = model, feasible = TRUE, error = NA_character_,
        grouped_q2 = grouped_metrics$q2,
        grouped_rmse = grouped_metrics$rmse,
        grouped_spearman = grouped_metrics$spearman,
        grouped_sensitivity = grouped_metrics$sensitivity,
        grouped_specificity = grouped_metrics$specificity,
        grouped_ppv = grouped_metrics$ppv,
        grouped_npv = grouped_metrics$npv,
        grouped_balanced_accuracy = grouped_metrics$balanced_accuracy,
        grouped_auc = grouped_metrics$auc,
        grouped_pr_auc = grouped_metrics$pr_auc,
        grouped_prevalence = grouped_metrics$prevalence,
        grouped_no_skill_pr_auc = grouped_metrics$no_skill_pr_auc,
        matched_random_q2 = matched_metrics$q2,
        matched_random_balanced_accuracy = matched_metrics$balanced_accuracy,
        matched_random_auc = matched_metrics$auc,
        matched_random_pr_auc = matched_metrics$pr_auc,
        matched_random_ppv = matched_metrics$ppv,
        matched_random_npv = matched_metrics$npv,
        grouped_effect = if (binary_outcome) grouped_metrics$auc else grouped_metrics$q2,
        matched_random_effect = if (binary_outcome) matched_metrics$auc else matched_metrics$q2,
        grouped_crossing = if (binary_outcome) {
          grouped_metrics$auc >= 0.60
        } else grouped_metrics$q2 >= 0.20,
        selected_components_grouped_median = median(object$grouped$ncomp),
        selected_components_matched_median = median(object$matched$ncomp),
        selected_components_grouped_at_ceiling = sum(
          object$grouped$ncomp == max(cfg$analysis$components)
        ),
        grouped_degenerate_inner_fold_events = if (binary_outcome) {
          sum(lengths(object$grouped$degenerate_inner_folds))
        } else NA_integer_,
        matched_degenerate_inner_fold_events = if (binary_outcome) {
          sum(lengths(object$matched$degenerate_inner_folds))
        } else NA_integer_,
        grouped_constant_fallback_outer_fits = if (binary_outcome) {
          sum(object$grouped$constant_classifier_fallback)
        } else NA_integer_,
        matched_constant_fallback_outer_fits = if (binary_outcome) {
          sum(object$matched$constant_classifier_fallback)
        } else NA_integer_,
        grouped_informative_component_selections = if (binary_outcome) {
          sum(object$grouped$component_selection_informative)
        } else NA_integer_,
        matched_informative_component_selections = if (binary_outcome) {
          sum(object$matched$component_selection_informative)
        } else NA_integer_,
        grouped_estimable_outer_fits = if (binary_outcome) {
          sum(object$grouped$outer_fit_estimable)
        } else NA_integer_,
        matched_estimable_outer_fits = if (binary_outcome) {
          sum(object$matched$outer_fit_estimable)
        } else NA_integer_,
        grouped_minimum_inner_training_positive = if (binary_outcome) {
          min(object$grouped$minimum_positive_training_count, na.rm = TRUE)
        } else NA_integer_,
        grouped_minimum_inner_training_negative = if (binary_outcome) {
          min(object$grouped$minimum_negative_training_count, na.rm = TRUE)
        } else NA_integer_
      )
    }), fill = TRUE)
    fold_audit <- data.table(
      outer_folds = uniqueN(grouped_outer),
      n_codes = uniqueN(code),
      maximum_outer_folds_per_code = max(vapply(
        split(grouped_outer, code), uniqueN, integer(1)
      )),
      minimum_codes_per_outer_fold = min(vapply(
        split(code, grouped_outer), uniqueN, integer(1)
      )),
      exact_outer_test_sizes_matched = identical(
        sort(as.integer(table(grouped_outer))), sort(as.integer(table(matched)))
      ),
      exact_outer_class_counts_matched = if (binary_outcome) {
        identical(unname(table(grouped_outer, y)), unname(table(matched, y)))
      } else NA,
      grouped_fold_hash = digest::digest(
        paste(d$patient, grouped_outer, sep = "="), algo = "sha256"
      ),
      matched_fold_hash = digest::digest(
        paste(d$patient, matched, sep = "="), algo = "sha256"
      ),
      error = NA_character_
    )
  }
  # A task-level fold-construction failure creates a compact error table above.
  # Complete the result schema here so the failure remains auditable and does
  # not prevent aggregation of the other representation-task estimates.
  result_defaults <- list(
    grouped_q2 = NA_real_, grouped_rmse = NA_real_,
    grouped_spearman = NA_real_, grouped_sensitivity = NA_real_,
    grouped_specificity = NA_real_, grouped_ppv = NA_real_,
    grouped_npv = NA_real_, grouped_balanced_accuracy = NA_real_,
    grouped_auc = NA_real_, grouped_pr_auc = NA_real_,
    grouped_prevalence = NA_real_, grouped_no_skill_pr_auc = NA_real_,
    matched_random_q2 = NA_real_, matched_random_balanced_accuracy = NA_real_,
    matched_random_auc = NA_real_, matched_random_pr_auc = NA_real_,
    matched_random_ppv = NA_real_, matched_random_npv = NA_real_,
    grouped_effect = NA_real_, matched_random_effect = NA_real_,
    grouped_crossing = FALSE,
    selected_components_grouped_median = NA_real_,
    selected_components_matched_median = NA_real_,
    selected_components_grouped_at_ceiling = NA_integer_,
    grouped_degenerate_inner_fold_events = NA_integer_,
    matched_degenerate_inner_fold_events = NA_integer_,
    grouped_constant_fallback_outer_fits = NA_integer_,
    matched_constant_fallback_outer_fits = NA_integer_,
    grouped_informative_component_selections = NA_integer_,
    matched_informative_component_selections = NA_integer_,
    grouped_estimable_outer_fits = NA_integer_,
    matched_estimable_outer_fits = NA_integer_,
    grouped_minimum_inner_training_positive = NA_integer_,
    grouped_minimum_inner_training_negative = NA_integer_
  )
  for (field in names(result_defaults)) {
    if (!field %chin% names(result)) {
      set(result, j = field, value = rep(result_defaults[[field]], nrow(result)))
    }
  }
  primary_columns <- c(
    TITAN = "screening_positive_TITAN",
    GigaSSL = "screening_positive_GigaSSL",
    ProvGigaPath = "screening_positive_ProvGigaPath"
  )
  result[, `:=`(
    grouped_job_id = i,
    primary_crossing = vapply(foundation_model, function(model) {
      isTRUE(job[[primary_columns[[model]]]][[1L]])
    }, logical(1)),
    outcome_type = job$outcome_type, family = job$family,
    subfamily = job$subfamily, tumor_type = job$tumor_type,
    endpoint = job$endpoint, source = job$source,
    n = nrow(d),
    positive = if (binary_outcome) sum(y == "1") else NA_integer_,
    negative = if (binary_outcome) sum(y == "0") else NA_integer_,
    supported_by_n = job$supported_by_n,
    primary_consensus_class = fcase(
      job$supported_by_n == 3L, "all three",
      job$supported_by_n == 2L, "exactly two",
      default = "representation specific"
    ),
    primary_effect = vapply(foundation_model, function(model) {
      as.numeric(job[[paste0("effect_", model)]][[1L]])
    }, numeric(1)),
    primary_operating_metric = vapply(foundation_model, function(model) {
      column <- paste0(if (binary_outcome) "auc_" else "q2_", model)
      as.numeric(job[[column]][[1L]])
    }, numeric(1)),
    seed = seed,
    fastPLS_version = as.character(packageVersion("fastPLS")),
    fastPLS_remote_sha = as.character(fastpls_description$RemoteSha)
  )]
  result[, retained_primary_crossing :=
           feasible & primary_crossing & grouped_crossing]
  result[, grouped_minus_matched_effect := grouped_effect - matched_random_effect]
  fold_audit[, `:=`(
    grouped_job_id = i, outcome_type = job$outcome_type,
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint,
    source = job$source, n = nrow(d),
    positive = if (binary_outcome) sum(y == "1") else NA_integer_,
    negative = if (binary_outcome) sum(y == "0") else NA_integer_, seed = seed
  )]
  code_prediction <- site_only_oof(y, code, binary_outcome, seed + 800000L)
  code_only <- data.table(
    grouped_job_id = i,
    code_only_metric = if (binary_outcome) rank_auc(y, code_prediction) else
      q_squared(y, code_prediction),
    code_prevalence_or_mean_range = diff(range(
      data.table(code = code, value = if (binary_outcome) as.integer(as.character(y)) else y)[
        , mean(value), by = code
      ]$V1
    )),
    n_codes = uniqueN(code)
  )
  tmp <- paste0(path, ".tmp-", Sys.getpid())
  saveRDS(list(fingerprint = fingerprint, result = result,
               fold_audit = fold_audit, code_only = code_only),
          tmp, compress = "xz")
  file.rename(tmp, path)
  NULL
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
if (!is.finite(workers) || workers < 1L) workers <- 1L
run_ids <- seq_len(nrow(jobs))
job_limit <- as.integer(Sys.getenv("FMPRED_TSS_JOB_LIMIT", "0"))
if (is.finite(job_limit) && job_limit > 0L) {
  run_ids <- head(run_ids, job_limit)
}
future::plan(future::multicore, workers = workers)
invisible(future_lapply(run_ids, run_job, future.seed = TRUE,
                        future.packages = c("fastPLS", "data.table"),
                        future.globals = TRUE, future.chunk.size = 1))
if (length(run_ids) < nrow(jobs)) {
  cat("Completed test subset:", length(run_ids), "of", nrow(jobs), "jobs\n")
  quit(save = "no", status = 0L)
}

paths <- vapply(seq_len(nrow(jobs)), checkpoint_path, character(1))
if (!all(file.exists(paths))) stop("Missing grouped-sensitivity checkpoints")
objects <- lapply(paths, readRDS)
result <- rbindlist(lapply(objects, `[[`, "result"), fill = TRUE)
fold_audit <- rbindlist(lapply(objects, `[[`, "fold_audit"), fill = TRUE)
code_only <- rbindlist(lapply(objects, `[[`, "code_only"), fill = TRUE)
setorder(result, outcome_type, family, tumor_type, endpoint, foundation_model)
fwrite(result, "results/tables/foundation_model_tss_grouped_sensitivity.csv")
fwrite(fold_audit, "results/tables/foundation_model_tss_grouped_fold_audit.csv")
fwrite(code_only, "results/tables/foundation_model_tss_code_only_outcomes.csv")

task <- result[, .(
  n = first(n), positive = first(positive), negative = first(negative),
  supported_by_n = first(supported_by_n),
  primary_consensus_class = first(primary_consensus_class),
  grouped_evaluable_representations = sum(feasible),
  primary_crossings_evaluable = sum(primary_crossing & feasible),
  primary_crossings_retained = sum(retained_primary_crossing),
  grouped_crossings_n = sum(grouped_crossing, na.rm = TRUE),
  complete_primary_retention = all(!primary_crossing | (feasible & grouped_crossing)),
  any_primary_retention = any(retained_primary_crossing),
  median_grouped_minus_matched_effect = median(grouped_minus_matched_effect, na.rm = TRUE)
), by = task_cols]
task[, sample_size_maturity := ifelse(
  outcome_type == "continuous", n >= 100L,
  positive >= 50L & negative >= 50L
)]
task[, tss_retention_class := fcase(
  primary_crossings_evaluable < supported_by_n, "not fully evaluable",
  primary_crossings_retained == supported_by_n, "complete retention",
  primary_crossings_retained > 0L, "partial retention",
  default = "no retention"
)]
task[, internal_robustness_class := fcase(
  sample_size_maturity & supported_by_n == 3L &
    tss_retention_class == "complete retention",
  "R1: all-three, mature, complete grouped retention",
  sample_size_maturity & supported_by_n >= 2L &
    tss_retention_class == "complete retention",
  "R2: multi-representation, mature, complete grouped retention",
  sample_size_maturity & any_primary_retention,
  "R3: mature with partial or single-representation retention",
  default = "R4: limited or cohort-structure-sensitive internal evidence"
)]
setorder(task, outcome_type, family, tumor_type, endpoint)
fwrite(task, "results/tables/foundation_model_internal_robustness_classification.csv")

cross_tab <- task[, .(tasks = .N), by = .(
  outcome_type, primary_consensus_class, sample_size_maturity,
  tss_retention_class, internal_robustness_class
)]
setorder(cross_tab, outcome_type, primary_consensus_class,
         sample_size_maturity, tss_retention_class)
fwrite(cross_tab, "results/tables/foundation_model_consensus_tss_crosstab.csv")

representation_summary <- result[, .(
  tasks = .N,
  primary_crossings = sum(primary_crossing),
  grouped_evaluable = sum(feasible),
  retained_primary_crossings = sum(retained_primary_crossing),
  retention_percent = 100 * sum(retained_primary_crossing) / sum(primary_crossing),
  grouped_crossings = sum(grouped_crossing, na.rm = TRUE),
  median_grouped_minus_primary_operating_metric = median(
    (if (outcome_type[[1L]] == "continuous") grouped_q2 else grouped_auc) -
      primary_operating_metric,
    na.rm = TRUE
  ),
  median_grouped_minus_matched_effect = median(grouped_minus_matched_effect,
                                                na.rm = TRUE)
), by = .(foundation_model, outcome_type)]
fwrite(representation_summary,
       "results/tables/foundation_model_tss_grouped_summary.csv")
print(representation_summary)
print(task[, .N, by = .(outcome_type, primary_consensus_class,
                         tss_retention_class)])
