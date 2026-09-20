.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))
options(backend = backend)
cohort <- readRDS("data/processed/patient_cohort.rds")

slides <- fread(cfg$paths$titan_features)
features <- cohort$feature_names
slides[, `:=`(patient = substr(filename, 1, 12),
              sample_type = substr(filename, 14, 15))]
slides <- slides[sample_type == "01" & grepl("-DX", filename)]
setorder(slides, patient, filename)
X_slide <- as.matrix(slides[, ..features])
storage.mode(X_slide) <- "double"
groups <- split(seq_len(nrow(slides)), slides$patient)
X_median <- cohort$X
for (patient in names(groups)[lengths(groups) > 1L]) {
  X_median[patient, ] <- apply(X_slide[groups[[patient]], , drop = FALSE], 2L, median)
}

continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- rbindlist(list(
  readRDS("data/processed/binary_targets_nonmutation.rds"),
  readRDS("data/processed/binary_targets_mutation.rds")
), use.names = TRUE)
continuous_jobs <- fread("results/tables/continuous_screen.csv")[tier %in% c("A", "B")]
binary_jobs <- fread("results/tables/binary_screen.csv")[tier %in% c("A", "B")]

fit_cont <- function(job, X, exclude_patient = NULL) {
  d <- continuous_targets[family == job$family & tumor_type == job$tumor_type &
                            endpoint == job$endpoint]
  if (!is.null(exclude_patient)) d <- d[patient != exclude_patient]
  idx <- match(d$patient, rownames(X))
  keep <- !is.na(idx) & is.finite(d$value)
  fit <- pls.double.cv(
    X[idx[keep], , drop = FALSE], d$value[keep],
    ncomp = cfg$analysis$components, rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed, perm.test = FALSE
  )
  list(n = sum(keep), metric = as.numeric(fit$Q2Y))
}

fit_bin <- function(job, X, exclude_patient = NULL) {
  d <- binary_targets[family == job$family & tumor_type == job$tumor_type &
                       endpoint == job$endpoint]
  if (!is.null(exclude_patient)) d <- d[patient != exclude_patient]
  idx <- match(d$patient, rownames(X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  y <- factor(d$value[keep], levels = c(0L, 1L))
  fit <- pls.double.cv(
    X[idx[keep], , drop = FALSE], y,
    ncomp = cfg$analysis$components,
    classifier = "lda", selection = "balanced_accuracy", rsvd_oversample = cfg$analysis$rsvd_oversample,
    rsvd_power = cfg$analysis$rsvd_power,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed, perm.test = FALSE
  )
  list(n = sum(keep), positive = sum(y == "1"),
       metric = balanced_accuracy(y, fit$Ypred))
}

run_median_cont <- function(i) {
  job <- continuous_jobs[i]
  z <- fit_cont(job, X_median)
  data.table(family = job$family, tumor_type = job$tumor_type,
             endpoint = job$endpoint, n = z$n,
             mean_pool_q2 = job$q2, median_pool_q2 = z$metric,
             delta_median_minus_mean = z$metric - job$q2, seed = job$seed)
}
run_median_bin <- function(i) {
  job <- binary_jobs[i]
  z <- fit_bin(job, X_median)
  data.table(family = job$family, tumor_type = job$tumor_type,
             endpoint = job$endpoint, n = z$n, positive = z$positive,
             mean_pool_balanced_accuracy = job$balanced_accuracy,
             median_pool_balanced_accuracy = z$metric,
             delta_median_minus_mean = z$metric - job$balanced_accuracy,
             seed = job$seed)
}

workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)
median_cont <- rbindlist(future_lapply(seq_len(nrow(continuous_jobs)),
  run_median_cont, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE))
median_bin <- rbindlist(future_lapply(seq_len(nrow(binary_jobs)),
  run_median_bin, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"), future.globals = TRUE))
fwrite(median_cont, "results/tables/continuous_median_pooling_sensitivity.csv")
fwrite(median_bin, "results/tables/binary_median_pooling_sensitivity.csv")

# The maximum-slide participant affects only SARC tasks. This analysis removes
# the participant before fold construction and refits every SARC candidate.
extreme_patient <- "TCGA-DX-AB2L"
sarc_cont_jobs <- continuous_jobs[tumor_type == "SARC"]
sarc_bin_jobs <- binary_jobs[tumor_type == "SARC"]
sarc_cont <- rbindlist(lapply(seq_len(nrow(sarc_cont_jobs)), function(i) {
  job <- sarc_cont_jobs[i]; z <- fit_cont(job, cohort$X, extreme_patient)
  data.table(family = job$family, tumor_type = job$tumor_type,
             endpoint = job$endpoint, original_n = job$n, exclusion_n = z$n,
             original_q2 = job$q2, exclusion_q2 = z$metric,
             delta_exclusion_minus_original = z$metric - job$q2,
             excluded_patient = extreme_patient, seed = job$seed)
}))
sarc_bin <- rbindlist(lapply(seq_len(nrow(sarc_bin_jobs)), function(i) {
  job <- sarc_bin_jobs[i]; z <- fit_bin(job, cohort$X, extreme_patient)
  data.table(family = job$family, tumor_type = job$tumor_type,
             endpoint = job$endpoint, original_n = job$n, exclusion_n = z$n,
             original_balanced_accuracy = job$balanced_accuracy,
             exclusion_balanced_accuracy = z$metric,
             delta_exclusion_minus_original = z$metric - job$balanced_accuracy,
             excluded_patient = extreme_patient, seed = job$seed)
}))
fwrite(sarc_cont, "results/tables/sarc_maximum_slide_patient_exclusion_continuous.csv")
fwrite(sarc_bin, "results/tables/sarc_maximum_slide_patient_exclusion_binary.csv")

summary <- rbindlist(list(
  median_cont[, .(outcome_type = "continuous", models = .N,
    median_delta = median(delta_median_minus_mean),
    q05_delta = quantile(delta_median_minus_mean, .05),
    q95_delta = quantile(delta_median_minus_mean, .95),
    correlation_with_mean = cor(mean_pool_q2, median_pool_q2, method = "spearman"),
    retained_original_effect_threshold = sum(median_pool_q2 >= 0.20))],
  median_bin[, .(outcome_type = "binary", models = .N,
    median_delta = median(delta_median_minus_mean),
    q05_delta = quantile(delta_median_minus_mean, .05),
    q95_delta = quantile(delta_median_minus_mean, .95),
    correlation_with_mean = cor(mean_pool_balanced_accuracy,
                                median_pool_balanced_accuracy, method = "spearman"),
    retained_original_effect_threshold = sum(median_pool_balanced_accuracy >= 0.60))]
), fill = TRUE)
fwrite(summary, "results/tables/median_pooling_sensitivity_summary.csv")
print(summary)
