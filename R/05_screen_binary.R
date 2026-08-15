.libPaths(c(normalizePath(".Rlib", mustWork = FALSE), .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(fastPLS)
  library(future.apply)
})
source("R/utils.R")
cfg <- load_project_config()
cohort <- readRDS("data/processed/patient_cohort.rds")
nonmutation <- readRDS("data/processed/binary_targets_nonmutation.rds")
mutation_path <- "data/processed/binary_targets_mutation.rds"
targets <- if (file.exists(mutation_path)) {
  rbindlist(list(nonmutation, readRDS(mutation_path)), use.names = TRUE)
} else nonmutation

catalog <- targets[, .(
  n = .N, positive = sum(value == 1L), negative = sum(value == 0L)
), by = .(family, subfamily, endpoint, tumor_type, source)]
jobs <- catalog[
  positive >= cfg$analysis$binary_min_positive &
    negative >= cfg$analysis$binary_min_negative
]
jobs[, job_id := .I]

checkpoint_dir <- "data/processed/checkpoints/binary"
dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)
workers <- as.integer(Sys.getenv("TITAN_WORKERS", "6"))
future::plan(future::multicore, workers = workers)

run_job <- function(i) {
  job <- jobs[i]
  checkpoint <- file.path(
    checkpoint_dir,
    paste0(safe_name(job$family, job$tumor_type, job$endpoint), ".rds")
  )
  if (file.exists(checkpoint)) return(NULL)
  d <- targets[
    family == job$family & tumor_type == job$tumor_type & endpoint == job$endpoint
  ]
  idx <- match(d$patient, rownames(cohort$X))
  keep <- !is.na(idx) & d$value %in% c(0L, 1L)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- factor(d$value[keep], levels = c(0L, 1L))
  seed <- cfg$analysis$seed + i
  fit_args <- list(
    Xdata = X, Ydata = y, ncomp = cfg$analysis$components,
    classifier = "lda", lda_ridge = cfg$analysis$lda_ridge,
    selection_metric = "balanced_accuracy",
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = seed
  )
  fit <- do.call(pls.double.cv, c(fit_args, list(perm.test = FALSE)))
  ba <- balanced_accuracy(y, fit$Ypred)
  adjusted_ba <- 2 * ba - 1
  # Performance is checkpointed for the complete atlas first. Only models able
  # to meet the effect threshold receive 99/999 permutations in R/05b.
  p <- 1; nperm <- 0L; exceed <- NA_integer_
  row <- data.table(
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint,
    source = job$source, n = length(y), positive = sum(y == "1"),
    negative = sum(y == "0"), balanced_accuracy = ba,
    adjusted_balanced_accuracy = 2 * ba - 1,
    p_permutation = p, permutations = nperm,
    permutation_exceedances = exceed,
    ncomp = as.integer(fit$bcomp), seed = seed,
    fastPLS_version = as.character(packageVersion("fastPLS"))
  )
  saveRDS(list(
    row = row,
    predictions = data.table(patient = d$patient[keep], observed = y,
                             predicted = fit$Ypred)
  ), checkpoint)
  NULL
}

invisible(future_lapply(
  seq_len(nrow(jobs)), run_job, future.seed = TRUE,
  future.packages = c("fastPLS", "data.table"),
  future.globals = TRUE, future.chunk.size = 1
))

objects <- lapply(list.files(checkpoint_dir, full.names = TRUE), readRDS)
results <- rbindlist(lapply(objects, `[[`, "row"), fill = TRUE)
results[, q_value := p.adjust(p_permutation, method = "BH"), by = family]
results[, tier := fifelse(
  q_value < cfg$analysis$fdr_alpha & adjusted_balanced_accuracy >= 0.40, "A",
  fifelse(q_value < cfg$analysis$fdr_alpha &
            adjusted_balanced_accuracy >= 0.20, "B", "C")
)]
setorder(results, family, -balanced_accuracy)
fwrite(results, "results/tables/binary_screen.csv")
saveRDS(lapply(objects, `[[`, "predictions"),
        "results/predictions/binary_oof_predictions.rds", compress = "xz")
print(results[, .N, by = .(family, tier)])
