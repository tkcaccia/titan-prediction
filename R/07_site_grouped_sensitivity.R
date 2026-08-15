.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
cohort <- readRDS("data/processed/patient_cohort.rds")
continuous_targets <- readRDS("data/processed/continuous_targets.rds")
binary_targets <- readRDS("data/processed/binary_targets_nonmutation.rds")
if (file.exists("data/processed/binary_targets_mutation.rds")) {
  binary_targets <- rbindlist(list(
    binary_targets, readRDS("data/processed/binary_targets_mutation.rds")
  ), use.names = TRUE)
}

continuous_jobs <- fread("results/tables/continuous_screen.csv")[tier %in% c("A", "B")]
binary_jobs <- fread("results/tables/binary_screen.csv")[tier %in% c("A", "B")]
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)

run_continuous <- function(i) {
  job <- continuous_jobs[i]
  d <- continuous_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X)); keep <- !is.na(idx) & is.finite(d$value)
  X <- cohort$X[idx[keep], , drop = FALSE]; y <- d$value[keep]
  site <- substr(d$patient[keep], 6, 7)
  grouped <- tryCatch(
    pls.double.cv(
      X, y, ncomp = cfg$analysis$components, constrain = site,
      kfold_outer = cfg$analysis$outer_folds,
      kfold_inner = cfg$analysis$inner_folds,
      seed = cfg$analysis$seed + i, perm.test = FALSE
    ), error = function(e) e
  )
  if (inherits(grouped, "error")) {
    return(data.table(
      family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
      n = length(y), n_sites = uniqueN(site), random_q2 = job$q2,
      site_grouped_q2 = NA_real_, delta = NA_real_, feasible = FALSE,
      error = conditionMessage(grouped)
    ))
  }
  q2_grouped <- as.numeric(grouped$Q2Y)
  data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    n = length(y), n_sites = uniqueN(site), random_q2 = job$q2,
    site_grouped_q2 = q2_grouped, delta = q2_grouped - job$q2,
    feasible = TRUE, error = NA_character_
  )
}

run_binary <- function(i) {
  job <- binary_jobs[i]
  d <- binary_targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X)); keep <- !is.na(idx) & d$value %in% c(0, 1)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value[keep], levels = c(0, 1)); site <- substr(d$patient[keep], 6, 7)
  grouped <- tryCatch(
    pls.double.cv(
      X, y, ncomp = cfg$analysis$components, constrain = site,
      classifier = "lda", lda_ridge = cfg$analysis$lda_ridge,
      selection_metric = "balanced_accuracy",
      kfold_outer = cfg$analysis$outer_folds,
      kfold_inner = cfg$analysis$inner_folds,
      seed = cfg$analysis$seed + i, perm.test = FALSE
    ), error = function(e) e
  )
  if (inherits(grouped, "error")) {
    return(data.table(
      family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
      n = length(y), positive = sum(y == "1"), n_sites = uniqueN(site),
      random_balanced_accuracy = job$balanced_accuracy,
      site_grouped_balanced_accuracy = NA_real_, delta = NA_real_,
      feasible = FALSE, error = conditionMessage(grouped)
    ))
  }
  ba <- balanced_accuracy(y, grouped$Ypred)
  data.table(
    family = job$family, tumor_type = job$tumor_type, endpoint = job$endpoint,
    n = length(y), positive = sum(y == "1"), n_sites = uniqueN(site),
    random_balanced_accuracy = job$balanced_accuracy,
    site_grouped_balanced_accuracy = ba,
    delta = ba - job$balanced_accuracy, feasible = TRUE,
    error = NA_character_
  )
}

continuous_out <- future_lapply(seq_len(nrow(continuous_jobs)), run_continuous,
                                future.seed = TRUE,
                                future.packages = c("fastPLS", "data.table"))
binary_out <- future_lapply(seq_len(nrow(binary_jobs)), run_binary,
                            future.seed = TRUE,
                            future.packages = c("fastPLS", "data.table"))
fwrite(rbindlist(continuous_out, fill = TRUE),
       "results/tables/continuous_site_grouped_sensitivity.csv")
fwrite(rbindlist(binary_out, fill = TRUE),
       "results/tables/binary_site_grouped_sensitivity.csv")

