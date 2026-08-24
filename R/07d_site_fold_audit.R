.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
})
source("R/utils.R")
cfg <- load_project_config()

cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_jobs <- fread("results/tables/continuous_screen.csv")[tier %chin% c("A", "B")]
binary_jobs <- fread("results/tables/binary_screen.csv")[tier %chin% c("A", "B")]

# This is the exact deterministic fold constructor used by fastPLS. Rebuilding
# the assignments from the endpoint labels, tissue-source-site constraint and
# recorded seed avoids re-fitting 323 models merely to audit fold composition.
make_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")

fold_rows <- function(job, i, outcome_type) {
  targets <- if (outcome_type == "continuous") continuous_targets else binary_targets
  d <- targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- if (outcome_type == "continuous") {
    !is.na(idx) & is.finite(d$value)
  } else {
    !is.na(idx) & d$value %in% c(0L, 1L)
  }
  patient <- d$patient[keep]
  site <- substr(patient, 6L, 7L)
  y <- if (outcome_type == "continuous") {
    d$value[keep]
  } else {
    factor(d$value[keep], levels = c(0L, 1L))
  }
  seed <- cfg$analysis$seed + i
  outer_zero <- make_folds(
    Ydata = y, constrain = site, kfold = cfg$analysis$outer_folds,
    seed = seed
  )
  outer_values <- sort(unique(outer_zero))
  rbindlist(lapply(seq_along(outer_values), function(f) {
    outer_value <- outer_values[[f]]
    test <- outer_zero == outer_value
    train <- !test
    inner_zero <- make_folds(
      Ydata = if (outcome_type == "continuous") y[train] else droplevels(y[train]),
      constrain = site[train], kfold = cfg$analysis$inner_folds,
      seed = seed + 1000L + f
    )
    inner_folds_per_site <- vapply(
      split(inner_zero, site[train]), uniqueN, integer(1L)
    )
    inner_sites_per_fold <- vapply(
      split(site[train], inner_zero), uniqueN, integer(1L)
    )
    data.table(
      outcome_type = outcome_type,
      family = job$family,
      tumor_type = job$tumor_type,
      endpoint = job$endpoint,
      outer_fold = f,
      test_patients = sum(test),
      test_sites = uniqueN(site[test]),
      test_site_ids = paste(sort(unique(site[test])), collapse = ";"),
      test_positive = if (outcome_type == "binary") sum(y[test] == "1") else NA_integer_,
      test_negative = if (outcome_type == "binary") sum(y[test] == "0") else NA_integer_,
      training_patients = sum(train),
      training_sites = uniqueN(site[train]),
      training_positive = if (outcome_type == "binary") sum(y[train] == "1") else NA_integer_,
      training_negative = if (outcome_type == "binary") sum(y[train] == "0") else NA_integer_,
      inner_folds = uniqueN(inner_zero),
      minimum_sites_per_inner_fold = min(inner_sites_per_fold),
      maximum_inner_folds_per_site = max(inner_folds_per_site),
      inner_site_overlap = any(inner_folds_per_site > 1L),
      outer_seed = seed,
      inner_seed = seed + 1000L + f
    )
  }))
}

continuous_folds <- rbindlist(lapply(seq_len(nrow(continuous_jobs)), function(i) {
  fold_rows(continuous_jobs[i], i, "continuous")
}))
binary_folds <- rbindlist(lapply(seq_len(nrow(binary_jobs)), function(i) {
  fold_rows(binary_jobs[i], i, "binary")
}))
folds <- rbindlist(list(continuous_folds, binary_folds), use.names = TRUE, fill = TRUE)
setorder(folds, outcome_type, family, tumor_type, endpoint, outer_fold)
fwrite(folds, "results/tables/site_grouped_outer_fold_composition.csv")

summary <- folds[, .(
  outer_folds = uniqueN(outer_fold),
  minimum_test_patients = min(test_patients),
  maximum_test_patients = max(test_patients),
  minimum_test_sites = min(test_sites),
  maximum_test_sites = max(test_sites),
  minimum_test_positive = if (outcome_type[[1L]] == "binary") min(test_positive) else NA_integer_,
  maximum_test_positive = if (outcome_type[[1L]] == "binary") max(test_positive) else NA_integer_,
  minimum_test_negative = if (outcome_type[[1L]] == "binary") min(test_negative) else NA_integer_,
  maximum_test_negative = if (outcome_type[[1L]] == "binary") max(test_negative) else NA_integer_,
  minimum_training_patients = min(training_patients),
  maximum_training_patients = max(training_patients),
  minimum_training_sites = min(training_sites),
  maximum_training_sites = max(training_sites),
  inner_site_grouped = !any(inner_site_overlap),
  maximum_inner_folds_per_site = max(maximum_inner_folds_per_site),
  minimum_sites_per_inner_fold = min(minimum_sites_per_inner_fold)
), by = .(outcome_type, family, tumor_type, endpoint)]
setorder(summary, outcome_type, family, tumor_type, endpoint)
fwrite(summary, "results/tables/site_grouped_fold_composition_summary.csv")

stopifnot(!any(folds$inner_site_overlap),
          all(folds$maximum_inner_folds_per_site == 1L),
          nrow(summary) == nrow(continuous_jobs) + nrow(binary_jobs))
cat("Audited", nrow(folds), "outer folds across", nrow(summary),
    "models; outer and inner folds both keep tissue-source sites intact.\n")
