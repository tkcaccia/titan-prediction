.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
})
source("R/utils.R")
cfg <- load_project_config()

# Fold-adequacy audit of the existing matched tissue-source-site-code grouped
# analysis. This script reconstructs the deterministic grouped outer and inner
# partitions; it does not fit or score any predictive model.
task_cols <- c("outcome_type", "family", "subfamily", "tumor_type",
               "endpoint", "source")
comparison <- fread("results/tables/foundation_model_target_comparison.csv")
jobs <- comparison[supported_by_n > 0L]
setorder(jobs, outcome_type, family, tumor_type, endpoint)
jobs[, grouped_job_id := .I]

cohorts <- lapply(c("TITAN", "GigaSSL", "ProvGigaPath"), function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
})
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
continuous <- readRDS("data/processed/continuous_targets.rds")[
  patient %chin% common_patients
]
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)[patient %chin% common_patients]
make_folds <- getFromNamespace(".make_single_cv_folds", "fastPLS")

class_counts <- function(y, index) {
  if (!is.factor(y)) {
    return(list(positive = NA_integer_, negative = NA_integer_))
  }
  list(
    positive = sum(y[index] == "1"),
    negative = sum(y[index] == "0")
  )
}

audit_job <- function(i) {
  job <- jobs[grouped_job_id == i]
  target <- if (job$outcome_type == "continuous") continuous else binary
  d <- target[
    family == job$family & subfamily == job$subfamily &
      tumor_type == job$tumor_type & endpoint == job$endpoint &
      source == job$source
  ]
  d <- if (job$outcome_type == "continuous") {
    d[is.finite(value)]
  } else {
    d[value %in% c(0L, 1L)]
  }
  setorder(d, patient)
  binary_outcome <- job$outcome_type == "binary"
  y <- if (binary_outcome) factor(d$value, levels = c(0L, 1L)) else d$value
  code <- substr(d$patient, 6L, 7L)
  seed <- cfg$analysis$seed + 700000L + i
  outer <- make_folds(
    Ydata = y, constrain = code, kfold = cfg$analysis$outer_folds,
    seed = seed
  )
  outer_levels <- sort(unique(outer))

  outer_rows <- rbindlist(lapply(seq_along(outer_levels), function(ff) {
    fold <- outer_levels[[ff]]
    test <- outer == fold
    train <- !test
    test_class <- class_counts(y, test)
    train_class <- class_counts(y, train)
    data.table(
      grouped_job_id = i,
      outer_fold = ff,
      test_n = sum(test),
      training_n = sum(train),
      test_codes = uniqueN(code[test]),
      training_codes = uniqueN(code[train]),
      test_positive = test_class$positive,
      test_negative = test_class$negative,
      training_positive = train_class$positive,
      training_negative = train_class$negative,
      single_class_test = if (binary_outcome) {
        test_class$positive == 0L || test_class$negative == 0L
      } else NA
    )
  }))

  inner_rows <- rbindlist(lapply(seq_along(outer_levels), function(ff) {
    outer_test <- outer == outer_levels[[ff]]
    outer_train <- !outer_test
    inner <- make_folds(
      Ydata = y[outer_train], constrain = code[outer_train],
      kfold = cfg$analysis$inner_folds, seed = seed + 2000L + ff
    )
    inner_levels <- sort(unique(inner))
    rbindlist(lapply(seq_along(inner_levels), function(ii) {
      validation <- inner == inner_levels[[ii]]
      training <- !validation
      validation_class <- class_counts(y[outer_train], validation)
      training_class <- class_counts(y[outer_train], training)
      data.table(
        grouped_job_id = i,
        outer_fold = ff,
        inner_fold = ii,
        inner_folds_realized = length(inner_levels),
        validation_n = sum(validation),
        training_n = sum(training),
        validation_codes = uniqueN(code[outer_train][validation]),
        training_codes = uniqueN(code[outer_train][training]),
        validation_positive = validation_class$positive,
        validation_negative = validation_class$negative,
        training_positive = training_class$positive,
        training_negative = training_class$negative,
        single_class_validation = if (binary_outcome) {
          validation_class$positive == 0L || validation_class$negative == 0L
        } else NA
      )
    }))
  }))

  reasons <- character()
  if (length(outer_levels) < cfg$analysis$outer_folds) {
    reasons <- c(reasons, "fewer_than_five_outer_folds")
  }
  if (min(outer_rows$test_n) < 10L) {
    reasons <- c(reasons, "outer_test_n_below_10")
  }
  if (binary_outcome && any(outer_rows$single_class_test)) {
    reasons <- c(reasons, "single_class_outer_test_fold")
  }
  if (binary_outcome && min(pmin(
    outer_rows$training_positive, outer_rows$training_negative
  )) < 20L) {
    reasons <- c(reasons, "outer_training_minority_below_20")
  }
  if (binary_outcome && any(inner_rows$single_class_validation)) {
    reasons <- c(reasons, "single_class_inner_validation_fold")
  }
  if (binary_outcome && any(
    inner_rows$training_positive == 0L | inner_rows$training_negative == 0L
  )) {
    reasons <- c(reasons, "single_class_inner_training_fold")
  }
  if (binary_outcome && min(pmin(
    inner_rows$training_positive, inner_rows$training_negative
  )) < 20L) {
    reasons <- c(reasons, "inner_training_minority_below_20")
  }
  if (!length(reasons)) reasons <- "none"

  row <- data.table(
    grouped_job_id = i,
    outcome_type = job$outcome_type,
    family = job$family,
    subfamily = job$subfamily,
    tumor_type = job$tumor_type,
    endpoint = job$endpoint,
    source = job$source,
    n = nrow(d),
    positive = if (binary_outcome) sum(y == "1") else NA_integer_,
    negative = if (binary_outcome) sum(y == "0") else NA_integer_,
    n_codes = uniqueN(code),
    requested_outer_folds = cfg$analysis$outer_folds,
    realized_outer_folds = length(outer_levels),
    outer_test_n_min = min(outer_rows$test_n),
    outer_test_n_max = max(outer_rows$test_n),
    outer_training_n_min = min(outer_rows$training_n),
    outer_test_codes_min = min(outer_rows$test_codes),
    outer_training_codes_min = min(outer_rows$training_codes),
    outer_test_positive_min = if (binary_outcome) min(outer_rows$test_positive) else NA_integer_,
    outer_test_negative_min = if (binary_outcome) min(outer_rows$test_negative) else NA_integer_,
    outer_training_positive_min = if (binary_outcome) min(outer_rows$training_positive) else NA_integer_,
    outer_training_negative_min = if (binary_outcome) min(outer_rows$training_negative) else NA_integer_,
    single_class_outer_test_folds = if (binary_outcome) sum(outer_rows$single_class_test) else NA_integer_,
    any_single_class_outer_test_fold = if (binary_outcome) any(outer_rows$single_class_test) else NA,
    inner_folds_realized_min = min(inner_rows$inner_folds_realized),
    inner_folds_realized_max = max(inner_rows$inner_folds_realized),
    inner_validation_n_min = min(inner_rows$validation_n),
    inner_training_n_min = min(inner_rows$training_n),
    inner_validation_codes_min = min(inner_rows$validation_codes),
    inner_training_codes_min = min(inner_rows$training_codes),
    inner_validation_positive_min = if (binary_outcome) min(inner_rows$validation_positive) else NA_integer_,
    inner_validation_negative_min = if (binary_outcome) min(inner_rows$validation_negative) else NA_integer_,
    inner_training_positive_min = if (binary_outcome) min(inner_rows$training_positive) else NA_integer_,
    inner_training_negative_min = if (binary_outcome) min(inner_rows$training_negative) else NA_integer_,
    single_class_inner_validation_folds = if (binary_outcome) sum(inner_rows$single_class_validation) else NA_integer_,
    any_single_class_inner_validation_fold = if (binary_outcome) any(inner_rows$single_class_validation) else NA,
    any_single_class_inner_training_fold = if (binary_outcome) any(
      inner_rows$training_positive == 0L | inner_rows$training_negative == 0L
    ) else NA,
    grouped_fold_adequacy_flag = if (identical(reasons, "none")) "no audit trigger" else "sparse grouped folds",
    grouped_fold_adequacy_reasons = paste(reasons, collapse = ";"),
    adequacy_flag_definition = paste(
      "Descriptive audit trigger: fewer than five realized outer folds,",
      "outer test n<10, a single-class binary outer test, inner validation or inner training fold,",
      "or fewer than 20 minority-class patients in any binary outer/inner training fit;",
      "not an exclusion or validity threshold."
    ),
    metric_construction = paste(
      "All outer held-out patient predictions pooled once; metrics calculated",
      "on pooled OOF predictions, not averaged fold-specific metrics."
    )
  )
  list(task = row, outer = outer_rows, inner = inner_rows)
}

audits <- lapply(seq_len(nrow(jobs)), audit_job)
task_audit <- rbindlist(lapply(audits, `[[`, "task"), fill = TRUE)
outer_audit <- rbindlist(lapply(audits, `[[`, "outer"), fill = TRUE)
inner_audit <- rbindlist(lapply(audits, `[[`, "inner"), fill = TRUE)

robustness_path <- "results/tables/foundation_model_internal_robustness_classification.csv"
robustness <- fread(robustness_path)
adequacy_cols <- c(
  "grouped_job_id", "n_codes", "requested_outer_folds",
  "realized_outer_folds", "outer_test_n_min", "outer_test_n_max",
  "outer_training_n_min", "outer_test_codes_min",
  "outer_training_codes_min", "outer_test_positive_min",
  "outer_test_negative_min", "outer_training_positive_min",
  "outer_training_negative_min", "single_class_outer_test_folds",
  "any_single_class_outer_test_fold", "inner_folds_realized_min",
  "inner_folds_realized_max", "inner_validation_n_min",
  "inner_training_n_min", "inner_validation_codes_min",
  "inner_training_codes_min", "inner_validation_positive_min",
  "inner_validation_negative_min", "inner_training_positive_min",
  "inner_training_negative_min", "single_class_inner_validation_folds",
  "any_single_class_inner_validation_fold", "grouped_fold_adequacy_flag",
  "any_single_class_inner_training_fold",
  "grouped_fold_adequacy_reasons", "adequacy_flag_definition",
  "metric_construction"
)
existing <- intersect(adequacy_cols, names(robustness))
if (length(existing)) robustness[, (existing) := NULL]
robustness <- merge(
  robustness,
  task_audit[, c(task_cols, adequacy_cols), with = FALSE],
  by = task_cols, all.x = TRUE, sort = FALSE
)
robustness[, deprecated_r1_r4_uses_flagged_grouped_result :=
             grouped_fold_adequacy_flag == "sparse grouped folds"]

grouped_path <- "results/tables/foundation_model_tss_grouped_sensitivity.csv"
grouped <- fread(grouped_path)
existing <- intersect(adequacy_cols, names(grouped))
if (length(existing)) grouped[, (existing) := NULL]
grouped <- merge(
  grouped,
  task_audit[, c(task_cols, adequacy_cols), with = FALSE],
  by = task_cols, all.x = TRUE, sort = FALSE
)

summary <- task_audit[, .(
  tasks = .N,
  representation_task_models = .N * 3L,
  tasks_with_four_outer_folds = sum(realized_outer_folds == 4L),
  tasks_with_outer_test_n_below_10 = sum(outer_test_n_min < 10L),
  tasks_with_single_class_outer_test_fold = sum(any_single_class_outer_test_fold %in% TRUE),
  tasks_with_single_class_inner_validation_fold = sum(any_single_class_inner_validation_fold %in% TRUE),
  tasks_with_single_class_inner_training_fold = sum(any_single_class_inner_training_fold %in% TRUE),
  tasks_with_outer_training_minority_below_20 = sum(
    pmin(outer_training_positive_min, outer_training_negative_min) < 20L,
    na.rm = TRUE
  ),
  tasks_with_inner_training_minority_below_20 = sum(
    pmin(inner_training_positive_min, inner_training_negative_min) < 20L,
    na.rm = TRUE
  ),
  tasks_with_sparse_grouped_folds = sum(grouped_fold_adequacy_flag == "sparse grouped folds"),
  minimum_outer_test_n = as.numeric(min(outer_test_n_min)),
  maximum_outer_test_n = as.numeric(max(outer_test_n_max)),
  minimum_outer_training_n = as.numeric(min(outer_training_n_min)),
  minimum_outer_training_positive = if (outcome_type[[1L]] == "binary") as.numeric(min(outer_training_positive_min)) else NA_real_,
  minimum_outer_training_negative = if (outcome_type[[1L]] == "binary") as.numeric(min(outer_training_negative_min)) else NA_real_,
  minimum_inner_training_positive = if (outcome_type[[1L]] == "binary") as.numeric(min(inner_training_positive_min)) else NA_real_,
  minimum_inner_training_negative = if (outcome_type[[1L]] == "binary") as.numeric(min(inner_training_negative_min)) else NA_real_
), by = outcome_type]

class_summary <- robustness[, .(
  tasks = .N,
  tasks_with_sparse_grouped_folds = sum(
    grouped_fold_adequacy_flag == "sparse grouped folds"
  ),
  percent_with_sparse_grouped_folds = 100 * mean(
    grouped_fold_adequacy_flag == "sparse grouped folds"
  )
), by = .(
  deprecated_r1_r4_class = sub(":.*$", "", internal_robustness_class)
)]

setorder(task_audit, outcome_type, family, tumor_type, endpoint)
setorder(outer_audit, grouped_job_id, outer_fold)
setorder(inner_audit, grouped_job_id, outer_fold, inner_fold)
setorder(robustness, outcome_type, family, tumor_type, endpoint)
setorder(grouped, outcome_type, family, tumor_type, endpoint, foundation_model)
setorder(summary, outcome_type)
setorder(class_summary, deprecated_r1_r4_class)

fwrite(task_audit, "results/tables/foundation_model_tss_grouped_fold_adequacy.csv")
fwrite(outer_audit, "results/tables/foundation_model_tss_grouped_outer_fold_composition.csv")
fwrite(inner_audit, "results/tables/foundation_model_tss_grouped_inner_fold_composition.csv")
fwrite(summary, "results/tables/foundation_model_tss_grouped_fold_adequacy_summary.csv")
fwrite(class_summary, "results/tables/foundation_model_tss_grouped_fold_adequacy_by_deprecated_class.csv")
fwrite(robustness, robustness_path)
fwrite(grouped, grouped_path)

# Apply the same audit vocabulary to the supporting permutation/FDR-filtered
# TITAN screen. Its historical fold table is the source of the 1--445-patient
# outer-test range discussed in the manuscript.
site_detail_path <- "results/tables/site_grouped_outer_fold_composition.csv"
site_summary_path <- "results/tables/site_grouped_fold_composition_summary.csv"
site_detail <- fread(site_detail_path)
titan_cohort <- readRDS("data/processed/patient_cohort.rds")
titan_continuous <- readRDS("data/processed/continuous_targets.rds")
titan_binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)

audit_titan_task <- function(key_row) {
  outcome <- key_row$outcome_type[[1L]]
  # The full TITAN screen is not restricted to the three-representation cohort.
  target <- if (outcome == "continuous") titan_continuous else titan_binary
  d <- target[
    family == key_row$family & tumor_type == key_row$tumor_type &
      endpoint == key_row$endpoint
  ]
  idx <- match(d$patient, rownames(titan_cohort$X))
  keep <- if (outcome == "continuous") {
    !is.na(idx) & is.finite(d$value)
  } else {
    !is.na(idx) & d$value %in% c(0L, 1L)
  }
  d <- d[keep]
  y <- if (outcome == "continuous") d$value else factor(d$value, levels = c(0L, 1L))
  code <- substr(d$patient, 6L, 7L)
  detail <- site_detail[
    outcome_type == outcome & family == key_row$family &
      tumor_type == key_row$tumor_type & endpoint == key_row$endpoint
  ]
  inner_rows <- rbindlist(lapply(seq_len(nrow(detail)), function(ii) {
    test_codes <- strsplit(detail$test_site_ids[[ii]], ";", fixed = TRUE)[[1L]]
    outer_train <- !(code %chin% test_codes)
    inner <- make_folds(
      Ydata = y[outer_train], constrain = code[outer_train],
      kfold = cfg$analysis$inner_folds, seed = detail$inner_seed[[ii]]
    )
    rbindlist(lapply(sort(unique(inner)), function(fold) {
      validation <- inner == fold
      training <- !validation
      validation_class <- class_counts(y[outer_train], validation)
      training_class <- class_counts(y[outer_train], training)
      data.table(
        validation_n = sum(validation), training_n = sum(training),
        validation_positive = validation_class$positive,
        validation_negative = validation_class$negative,
        training_positive = training_class$positive,
        training_negative = training_class$negative,
        single_class_validation = if (outcome == "binary") {
          validation_class$positive == 0L || validation_class$negative == 0L
        } else NA
      )
    }))
  }))
  reasons <- character()
  if (nrow(detail) < cfg$analysis$outer_folds) {
    reasons <- c(reasons, "fewer_than_five_outer_folds")
  }
  if (min(detail$test_patients) < 10L) {
    reasons <- c(reasons, "outer_test_n_below_10")
  }
  if (outcome == "binary" && any(
    detail$test_positive == 0L | detail$test_negative == 0L
  )) {
    reasons <- c(reasons, "single_class_outer_test_fold")
  }
  if (outcome == "binary" && min(pmin(
    detail$training_positive, detail$training_negative
  )) < 20L) {
    reasons <- c(reasons, "outer_training_minority_below_20")
  }
  if (outcome == "binary" && any(inner_rows$single_class_validation)) {
    reasons <- c(reasons, "single_class_inner_validation_fold")
  }
  if (outcome == "binary" && any(
    inner_rows$training_positive == 0L | inner_rows$training_negative == 0L
  )) {
    reasons <- c(reasons, "single_class_inner_training_fold")
  }
  if (outcome == "binary" && min(pmin(
    inner_rows$training_positive, inner_rows$training_negative
  )) < 20L) {
    reasons <- c(reasons, "inner_training_minority_below_20")
  }
  if (!length(reasons)) reasons <- "none"
  data.table(
    outcome_type = outcome, family = key_row$family,
    tumor_type = key_row$tumor_type, endpoint = key_row$endpoint,
    single_class_outer_test_folds = if (outcome == "binary") sum(
      detail$test_positive == 0L | detail$test_negative == 0L
    ) else NA_integer_,
    any_single_class_outer_test_fold = if (outcome == "binary") any(
      detail$test_positive == 0L | detail$test_negative == 0L
    ) else NA,
    outer_training_positive_min = if (outcome == "binary") min(detail$training_positive) else NA_integer_,
    outer_training_negative_min = if (outcome == "binary") min(detail$training_negative) else NA_integer_,
    inner_validation_n_min = min(inner_rows$validation_n),
    inner_training_n_min = min(inner_rows$training_n),
    inner_validation_positive_min = if (outcome == "binary") min(inner_rows$validation_positive) else NA_integer_,
    inner_validation_negative_min = if (outcome == "binary") min(inner_rows$validation_negative) else NA_integer_,
    inner_training_positive_min = if (outcome == "binary") min(inner_rows$training_positive) else NA_integer_,
    inner_training_negative_min = if (outcome == "binary") min(inner_rows$training_negative) else NA_integer_,
    single_class_inner_validation_folds = if (outcome == "binary") sum(inner_rows$single_class_validation) else NA_integer_,
    any_single_class_inner_validation_fold = if (outcome == "binary") any(inner_rows$single_class_validation) else NA,
    any_single_class_inner_training_fold = if (outcome == "binary") any(
      inner_rows$training_positive == 0L | inner_rows$training_negative == 0L
    ) else NA,
    grouped_fold_adequacy_flag = if (identical(reasons, "none")) "no audit trigger" else "sparse grouped folds",
    grouped_fold_adequacy_reasons = paste(reasons, collapse = ";"),
    adequacy_flag_definition = task_audit$adequacy_flag_definition[[1L]],
    metric_construction = task_audit$metric_construction[[1L]]
  )
}

site_keys <- unique(site_detail[, .(outcome_type, family, tumor_type, endpoint)])
site_adequacy <- rbindlist(lapply(seq_len(nrow(site_keys)), function(i) {
  audit_titan_task(site_keys[i])
}))
site_summary <- fread(site_summary_path)
site_new_cols <- setdiff(names(site_adequacy),
                         c("outcome_type", "family", "tumor_type", "endpoint"))
existing <- intersect(site_new_cols, names(site_summary))
if (length(existing)) site_summary[, (existing) := NULL]
site_summary <- merge(
  site_summary, site_adequacy,
  by = c("outcome_type", "family", "tumor_type", "endpoint"),
  all.x = TRUE, sort = FALSE
)
site_adequacy_summary <- site_summary[, .(
  models = .N,
  models_with_four_outer_folds = sum(outer_folds == 4L),
  models_with_outer_test_n_below_10 = sum(minimum_test_patients < 10L),
  models_with_single_class_outer_test_fold = sum(any_single_class_outer_test_fold %in% TRUE),
  models_with_single_class_inner_validation_fold = sum(any_single_class_inner_validation_fold %in% TRUE),
  models_with_single_class_inner_training_fold = sum(any_single_class_inner_training_fold %in% TRUE),
  models_with_sparse_grouped_folds = sum(grouped_fold_adequacy_flag == "sparse grouped folds"),
  minimum_outer_test_n = min(minimum_test_patients),
  maximum_outer_test_n = max(maximum_test_patients),
  minimum_outer_training_n = min(minimum_training_patients),
  minimum_outer_training_positive = if (outcome_type[[1L]] == "binary") as.numeric(min(outer_training_positive_min)) else NA_real_,
  minimum_outer_training_negative = if (outcome_type[[1L]] == "binary") as.numeric(min(outer_training_negative_min)) else NA_real_,
  minimum_inner_training_positive = if (outcome_type[[1L]] == "binary") as.numeric(min(inner_training_positive_min)) else NA_real_,
  minimum_inner_training_negative = if (outcome_type[[1L]] == "binary") as.numeric(min(inner_training_negative_min)) else NA_real_
), by = outcome_type]
setorder(site_summary, outcome_type, family, tumor_type, endpoint)
setorder(site_adequacy_summary, outcome_type)
fwrite(site_summary, site_summary_path)
fwrite(site_adequacy_summary,
       "results/tables/site_grouped_fold_adequacy_summary.csv")

attach_titan_flag <- function(path, outcome) {
  x <- fread(path)
  existing <- intersect(site_new_cols, names(x))
  if (length(existing)) x[, (existing) := NULL]
  x <- merge(
    x, site_adequacy[outcome_type == outcome],
    by = c("family", "tumor_type", "endpoint"), all.x = TRUE, sort = FALSE
  )
  x[, outcome_type := NULL]
  fwrite(x, path)
}
attach_titan_flag("results/tables/continuous_site_grouped_sensitivity.csv", "continuous")
attach_titan_flag("results/tables/binary_site_grouped_sensitivity.csv", "binary")

print(summary)
print(class_summary)
print(site_adequacy_summary)
