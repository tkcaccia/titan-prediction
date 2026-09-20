.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages(library(data.table))
source("R/utils.R")
cfg <- load_project_config()
models <- c("TITAN", "GigaSSL", "ProvGigaPath")
cohorts <- setNames(lapply(models, function(model) {
  readRDS(file.path("data/processed", paste0("patient_cohort_", model, ".rds")))
}), models)
common_patients <- Reduce(intersect, lapply(cohorts, function(x) rownames(x$X)))
continuous <- readRDS("data/processed/continuous_targets.rds")[patient %chin% common_patients]
binary <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)[patient %chin% common_patients]
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
checkpoint_dir <- "data/processed/checkpoints/foundation_model_comparison_common_patient"
jobs[, checkpoint := file.path(checkpoint_dir, paste0(
  mapply(safe_name, outcome_type, family, tumor_type, endpoint), ".rds"
))]
missing <- jobs[!file.exists(checkpoint)]
missing[, zero_sd_outer_training_folds := vapply(seq_len(.N), function(i) {
  job <- missing[i]
  d <- if (job$outcome_type == "continuous") continuous else binary
  d <- d[
    family == job$family & tumor_type == job$tumor_type &
      endpoint == job$endpoint
  ]
  d <- d[is.finite(value)]
  setorder(d, patient)
  folds <- random_folds(nrow(d), cfg$analysis$outer_folds,
                        cfg$analysis$seed + job$job_id)
  sum(vapply(seq_len(cfg$analysis$outer_folds), function(fold) {
    sd(d$value[folds != fold]) == 0
  }, logical(1)))
}, integer(1))]
print(missing[, .(job_id, outcome_type, family, tumor_type, endpoint, n,
                  positive, negative, zero_sd_outer_training_folds,
                  checkpoint)])
fwrite(missing, "results/tables/foundation_model_missing_jobs.csv")
