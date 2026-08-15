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
catalog <- fread("results/tables/continuous_target_catalog.csv")
jobs <- catalog[n >= cfg$analysis$continuous_min_n & is.finite(sd) & sd > 0]
jobs[, job_id := .I]

checkpoint_dir <- "data/processed/checkpoints/continuous"
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
  keep <- !is.na(idx) & is.finite(d$value)
  X <- cohort$X[idx[keep], , drop = FALSE]
  y <- d$value[keep]
  seed <- cfg$analysis$seed + i
  fit <- pls.double.cv(
    X, y, ncomp = cfg$analysis$components,
    kfold_outer = cfg$analysis$outer_folds,
    kfold_inner = cfg$analysis$inner_folds,
    seed = seed, perm.test = FALSE
  )
  q2 <- as.numeric(fit$Q2Y)
  # Performance is checkpointed for the complete atlas first. Only models able
  # to meet the effect threshold receive 99/999 permutations in R/05b.
  p <- 1; nperm <- 0L; exceed <- NA_integer_
  row <- data.table(
    family = job$family, subfamily = job$subfamily,
    tumor_type = job$tumor_type, endpoint = job$endpoint,
    source = job$source, n = length(y), q2 = q2,
    rmse = sqrt(mean((y - as.numeric(fit$Ypred))^2)),
    spearman = suppressWarnings(cor(y, as.numeric(fit$Ypred), method = "spearman")),
    p_permutation = p, permutations = nperm,
    permutation_exceedances = exceed,
    ncomp = as.integer(fit$bcomp), seed = seed,
    fastPLS_version = as.character(packageVersion("fastPLS"))
  )
  saveRDS(list(
    row = row,
    predictions = data.table(patient = d$patient[keep], observed = y,
                             predicted = as.numeric(fit$Ypred))
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
  q_value < cfg$analysis$fdr_alpha & q2 >= 0.40, "A",
  fifelse(q_value < cfg$analysis$fdr_alpha & q2 >= 0.20, "B", "C")
)]
setorder(results, family, -q2)
fwrite(results, "results/tables/continuous_screen.csv")
saveRDS(lapply(objects, `[[`, "predictions"),
        "results/predictions/continuous_oof_predictions.rds", compress = "xz")
print(results[, .N, by = .(family, tier)])
