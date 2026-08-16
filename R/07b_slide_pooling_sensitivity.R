.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(fastPLS.backend = backend)
cohort <- readRDS("data/processed/patient_cohort.rds")

# Sensitivity analysis only. Mean pooling is the prespecified primary input.
# Here the lexicographically first eligible diagnostic slide is substituted,
# while preserving patient order, endpoints, seeds and all nested-CV settings.
slides <- fread(cfg$paths$titan_features)
feature_names <- cohort$feature_names
slides[, `:=`(
  patient = substr(filename, 1, 12),
  sample_type = substr(filename, 14, 15)
)]
slides <- slides[sample_type == "01" & grepl("-DX", filename)]
setorder(slides, patient, filename)
first <- slides[, .SD[1L], by = patient, .SDcols = c("filename", feature_names)]
idx <- match(cohort$meta$patient, first$patient)
stopifnot(!anyNA(idx))
X_first <- as.matrix(first[idx, ..feature_names])
rownames(X_first) <- cohort$meta$patient

continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_jobs <- fread("results/tables/continuous_screen.csv")[tier %in% c("A", "B")]
binary_jobs <- fread("results/tables/binary_screen.csv")[tier %in% c("A", "B")]

run_continuous <- function(i) {
  job <- continuous_jobs[i]
  d <- continuous_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(X_first))
  keep <- !is.na(idx) & is.finite(d$value)
  fit <- pls.double.cv(
    X_first[idx[keep], , drop = FALSE], d$value[keep],
    ncomp = cfg$analysis$components,
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed, perm.test = FALSE
  )
  data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    n = sum(keep), multi_slide_patients = sum(
      cohort$meta$n_slides[match(d$patient[keep], cohort$meta$patient)] > 1
    ), mean_pool_q2 = job$q2, first_slide_q2 = as.numeric(fit$Q2Y),
    delta_first_minus_mean = as.numeric(fit$Q2Y) - job$q2,
    seed = job$seed,
    backend = backend, svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power
  )
}

run_binary <- function(i) {
  job <- binary_jobs[i]
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(X_first))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  y <- factor(d$value[keep], levels = c(0L, 1L))
  fit <- pls.double.cv(
    X_first[idx[keep], , drop = FALSE], y,
    ncomp = cfg$analysis$components,
    classifier = "lda", lda_ridge = cfg$analysis$lda_ridge,
    selection_metric = "balanced_accuracy",
    svd.method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed, perm.test = FALSE
  )
  ba <- balanced_accuracy(y, fit$Ypred)
  data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    n = sum(keep), positive = sum(y == "1"),
    multi_slide_patients = sum(
      cohort$meta$n_slides[match(d$patient[keep], cohort$meta$patient)] > 1
    ), mean_pool_balanced_accuracy = job$balanced_accuracy,
    first_slide_balanced_accuracy = ba,
    delta_first_minus_mean = ba - job$balanced_accuracy,
    seed = job$seed,
    backend = backend, svd_method = cfg$analysis$svd_method,
    rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power
  )
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
continuous_out <- future_lapply(
  seq_len(nrow(continuous_jobs)), run_continuous, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE
)
binary_out <- future_lapply(
  seq_len(nrow(binary_jobs)), run_binary, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE
)
fwrite(rbindlist(continuous_out, fill = TRUE),
       "results/tables/continuous_slide_pooling_sensitivity.csv")
fwrite(rbindlist(binary_out, fill = TRUE),
       "results/tables/binary_slide_pooling_sensitivity.csv")
