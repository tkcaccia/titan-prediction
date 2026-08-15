#!/usr/bin/env Rscript
.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")

cfg <- load_project_config()
cohort <- readRDS("data/processed/patient_cohort.rds")
targets <- readRDS("data/processed/continuous_targets.rds")
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "1"))
times <- as.integer(Sys.getenv("TITAN_BENCHMARK_PERMUTATIONS", "9"))
xprod <- identical(tolower(Sys.getenv("TITAN_XPROD", "false")), "true")
backend <- tolower(Sys.getenv("TITAN_BACKEND", "cpu"))

files <- list.files("data/processed/checkpoints/continuous", pattern = "[.]rds$", full.names = TRUE)
jobs <- rbindlist(lapply(files, function(path) {
  row <- readRDS(path)$row
  if (is.finite(row$q2) && row$q2 >= cfg$analysis$continuous_effect_gate && row$permutations == 0L) {
    row[, path := path]
  } else NULL
}), fill = TRUE)
setorder(jobs, -n)
jobs <- jobs[seq_len(min(4L, .N))]

one <- function(i) {
  job <- jobs[i]
  d <- targets[family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & is.finite(d$value)
  fit <- pls.double.cv(
    cohort$X[idx[keep], , drop = FALSE], d$value[keep],
    ncomp = cfg$analysis$components,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = job$seed, perm.test = TRUE, times = times,
    backend = backend, xprod = xprod
  )
  c(n = sum(keep), q2 = as.numeric(fit$Q2Y))
}

if (workers == 1L) {
  future::plan(future::sequential)
} else {
  future::plan(future::multicore, workers = workers)
}
elapsed <- system.time({
  ans <- future_lapply(seq_len(nrow(jobs)), one, future.seed = TRUE,
                       future.packages = c("fastPLS", "data.table"),
                       future.globals = TRUE, future.chunk.size = 1)
})[["elapsed"]]
cat(sprintf("backend=%s workers=%d jobs=%d permutations=%d xprod=%s elapsed_seconds=%.3f\n",
            backend, workers, nrow(jobs), times, xprod, elapsed))
print(rbindlist(lapply(seq_along(ans), function(i) {
  data.table(tumor_type = jobs$tumor_type[i], endpoint = jobs$endpoint[i],
             n = ans[[i]][["n"]], q2 = ans[[i]][["q2"]])
})))
